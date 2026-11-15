import 'dart:async';
import 'dart:io';

import 'package:dox_cache/dox_cache.dart';
import 'package:dox_core/dox_core.dart' show Env;

import 'bounded_sink.dart';
import 'constants/schedule_constants.dart';
import 'scheduled_task.dart';
import 'scheduler_flags.dart';
import 'scheduler_log.dart';

/// Gives the time and waits. Inject a fake one in tests to move time.
class ScheduleClock {
  const ScheduleClock();

  /// The time now, in UTC.
  DateTime now() {
    return DateTime.now().toUtc();
  }

  /// Wait for [duration]. `work` cancels every timer that starts inside
  /// `sleep` when the sleep ends or the scheduler stops. So a custom
  /// `sleep` must not start a timer for other work; it would never fire.
  Future<void> sleep(Duration duration) {
    return Future<void>.delayed(duration);
  }
}

/// What happened to a task in one tick.
enum TaskOutcome {
  /// It ran and did not throw.
  ran,

  /// A filter or a lock stopped it.
  skipped,

  /// It (or a `before` hook) threw or timed out.
  failed,
}

/// Runs the tasks. `SchedulerRunner` and `SchedulerProvider` use it.
///
/// ```
/// Scheduler scheduler = Scheduler(tasks: s.tasks, store: store);
/// await scheduler.runDue();
/// ```
class Scheduler {
  Scheduler({
    required this.tasks,
    required this.store,
    this.clock = const ScheduleClock(),
    StringSink? out,
    StringSink? err,
    this.flags = const SchedulerFlags(),
  }) : out = out ?? BoundedSink(),
       err = err ?? stderr;

  final List<ScheduledTask> tasks;

  /// The lock store. Share it (Redis) between servers.
  final CacheStore store;

  final ScheduleClock clock;

  /// Log lines go here. The default keeps only the last 64 KB, so a
  /// long run does not fill the memory. See [SchedulerFlags.loggerLines]
  /// for the app Logger.
  final StringSink out;

  /// Opt-in behaviors. `SchedulerRunner` and `SchedulerProvider` pass
  /// `ScheduleConfig.flags`.
  final SchedulerFlags flags;

  /// Warnings go here. Default: stderr.
  final StringSink err;

  bool _lockChecked = false;

  /// Running tasks, so a stop can wait for them.
  final Set<Future<TaskOutcome>> _running = <Future<TaskOutcome>>{};

  /// Overlap locks of timed-out runs whose work still goes on.
  final Set<CacheLock> _lateLocks = <CacheLock>{};

  bool _stopping = false;

  /// End the running [_wait] calls at [stop]. Each wait adds its own
  /// completer and removes it after. One shared completer that never ends
  /// would keep one listener per wait forever: a slow memory leak, about
  /// 0.4 MB a day.
  final Set<Completer<void>> _wakes = <Completer<void>>{};

  /// Timers the clock made while [work] sleeps. They are cancelled after
  /// each sleep, so a stop does not leave a timer that keeps the process
  /// alive until the next minute.
  final Set<Timer> _sleepTimers = <Timer>{};

  /// The cache store for the locks: [name] of [manager], or the default
  /// store. A store without locks (null, and file before dox_cache 3.0.2)
  /// gives a memory store. See [warnIfLockNotShared].
  static CacheStore lockStore(CacheManager manager, String? name) {
    CacheStore store = manager.store(name);
    try {
      store.lock(ScheduleConstants.lockPrefix);
      return store;
    } on UnsupportedError {
      return CacheStore(MemoryDriver());
    }
  }

  /// Print one warning to [err] when a task uses `onOneServer()` but the
  /// lock store is not shared between servers (memory or file). Then the
  /// lock works only inside one server. It prints at most once.
  /// `runDue` and `work` call it. It does not print when `APP_ENV` is
  /// `development` or `local`: a dev machine is one server.
  void warnIfLockNotShared() {
    if (_lockChecked) return;
    _lockChecked = true;
    String env = Env.get<String>('APP_ENV').trim().toLowerCase();
    if (env == 'development' || env == 'local') return;
    CacheDriver driver = store.driver;
    // ponytail: only the drivers we know are local; a custom driver may be shared
    if (driver is! MemoryDriver && driver is! FileDriver) return;
    bool oneServer = false;
    for (ScheduledTask task in tasks) {
      if (task.oneServer) oneServer = true;
    }
    if (!oneServer) return;
    String kind = driver is FileDriver ? 'file' : 'memory';
    String text =
        'the lock store is a $kind store. It is not '
        'shared between servers, so onOneServer() works only inside one '
        'server. When many servers run the schedule, each server runs the '
        "task. Use a Redis cache store: ScheduleConfig(store: 'redis').";
    SchedulerLog.write(
      err,
      flags,
      SchedulerLogLevel.warn,
      '[schedule] warning: $text',
      text,
    );
  }

  /// The start of the minute of [time], in UTC.
  static DateTime minuteOf(DateTime time) {
    int ms = time.millisecondsSinceEpoch;
    return DateTime.fromMillisecondsSinceEpoch(ms - ms % 60000, isUtc: true);
  }

  /// Run the tasks that are due at the minute [tick] (default: now).
  /// It waits for each task before the next one, but starts
  /// `runInBackground()` tasks and goes on. With [waitForBackground] it
  /// waits for those too at the end. Gives the outcome of each task it
  /// waited for, by name.
  Future<Map<String, TaskOutcome>> runDue({
    DateTime? tick,
    bool waitForBackground = false,
  }) async {
    warnIfLockNotShared();
    DateTime minute = minuteOf(tick ?? clock.now());
    return _runAt(minute, 0, waitForBackground);
  }

  /// Run the repeats of the sub-minute tasks (`everySecond()` and the
  /// like) that are due at [minute], for the rest of that minute. It
  /// sleeps between the steps and ends when the minute ends or at
  /// [stop]. Call it after `runDue(tick: minute)`. A slow run skips the
  /// steps it missed. With no due sub-minute task it ends at once.
  /// Gives the outcome of each task: a failed run stays failed.
  Future<Map<String, TaskOutcome>> runRepeats(
    DateTime minute, {
    bool waitForBackground = false,
  }) async {
    minute = minuteOf(minute);
    Map<String, TaskOutcome> outcomes = <String, TaskOutcome>{};
    int step = 60;
    for (ScheduledTask task in tasks) {
      int? seconds = task.repeatSeconds;
      if (seconds != null && _isDue(task, minute)) step = step.gcd(seconds);
    }
    if (step == 60) return outcomes;
    int offset = 0;
    while (!_stopping) {
      int elapsed = clock.now().difference(minute).inMilliseconds;
      // the next step after now (ceil), and never the same step again
      int late = (elapsed + step * 1000 - 1) ~/ (step * 1000) * step;
      offset = late > offset + step ? late : offset + step;
      if (offset >= 60) break;
      DateTime at = minute.add(Duration(seconds: offset));
      await _wait(at.difference(clock.now()));
      if (_stopping) break;
      Map<String, TaskOutcome> ran = await _runAt(
        at,
        offset,
        waitForBackground,
      );
      for (MapEntry<String, TaskOutcome> entry in ran.entries) {
        if (outcomes[entry.key] != TaskOutcome.failed) {
          outcomes[entry.key] = entry.value;
        }
      }
    }
    return outcomes;
  }

  /// Run the due tasks at [at]. At [offset] 0 (the minute start) every
  /// due task runs. At a later second only the sub-minute tasks whose
  /// step fits [offset] run.
  Future<Map<String, TaskOutcome>> _runAt(
    DateTime at,
    int offset,
    bool waitForBackground,
  ) async {
    DateTime minute = minuteOf(at);
    Map<String, TaskOutcome> outcomes = <String, TaskOutcome>{};
    Map<String, Future<TaskOutcome>> background =
        <String, Future<TaskOutcome>>{};
    for (ScheduledTask task in tasks) {
      if (_stopping) break;
      int? seconds = task.repeatSeconds;
      if (offset != 0 && (seconds == null || offset % seconds != 0)) continue;
      if (!_isDue(task, minute)) continue;
      Future<TaskOutcome> run = runTask(task, at);
      if (task.background) {
        background[task.name] = run;
      } else {
        outcomes[task.name] = await run;
      }
    }
    if (waitForBackground) {
      for (MapEntry<String, Future<TaskOutcome>> entry in background.entries) {
        outcomes[entry.key] = await entry.value;
      }
    }
    return outcomes;
  }

  DateTime? _dueMinute;
  final Map<ScheduledTask, bool> _dueCache = <ScheduledTask, bool>{};

  /// [ScheduledTask.isDue] once per task and minute. The sub-minute steps
  /// of one minute ask again and again with the same answer.
  ///
  /// A task's schedule must not change while the scheduler runs. The
  /// answer is kept for the minute.
  bool _isDue(ScheduledTask task, DateTime minute) {
    if (_dueMinute != minute) {
      _dueMinute = minute;
      _dueCache.clear();
    }
    return _dueCache[task] ??= task.isDue(minute);
  }

  /// Run [task] for the minute [tick]: filters, locks, hooks and the
  /// work. For a sub-minute task [tick] is cut to its step, like
  /// 02:00:05, so each repeat has its own once-per-tick lock. With
  /// [force] (the `test` command) the filters and locks are not checked.
  Future<TaskOutcome> runTask(
    ScheduledTask task,
    DateTime tick, {
    bool force = false,
  }) {
    int stepMs = (task.repeatSeconds ?? 60) * 1000;
    int ms = tick.millisecondsSinceEpoch;
    DateTime at = DateTime.fromMillisecondsSinceEpoch(
      ms - ms % stepMs,
      isUtc: true,
    );
    Future<TaskOutcome> run = _run(task, at, force);
    _running.add(run);
    return _forget(run);
  }

  /// Wait for every running task.
  Future<void> idle() async {
    while (_running.isNotEmpty) {
      await Future.wait(List<Future<TaskOutcome>>.of(_running));
    }
  }

  /// Run due tasks at every minute boundary until [stop]. The first
  /// tick is the next full minute. Sub-minute tasks repeat inside the
  /// minute (see [runRepeats]). After [stop] it waits for the running
  /// tasks.
  ///
  /// When the work of a tick ends in a later minute, that minute runs at
  /// once, with no wait. Only the minute of now runs: the minutes in
  /// between are not run later. This is the same rule as after a long
  /// pause (a sleeping laptop). A minute never runs twice.
  Future<void> work() async {
    warnIfLockNotShared();
    DateTime? last;
    while (!_stopping) {
      DateTime now = clock.now();
      DateTime tick = minuteOf(now);
      if (last == null || !tick.isAfter(last)) {
        DateTime next = tick.add(const Duration(minutes: 1));
        await _wait(next.difference(now));
        if (_stopping) break;
        // after a long pause (sleeping laptop) run the minute of now
        DateTime late = minuteOf(clock.now());
        tick = late.isAfter(next) ? late : next;
        // the clock went back: wait until it passes the last tick
        if (last != null && !tick.isAfter(last)) continue;
      }
      last = tick;
      await runDue(tick: tick);
      await runRepeats(tick);
    }
    await idle();
    await close();
  }

  /// Sleep for [duration], or until [stop].
  Future<void> _wait(Duration duration) async {
    if (_stopping) return;
    Completer<void> wake = Completer<void>();
    _wakes.add(wake);
    try {
      await Future.any(<Future<void>>[_sleep(duration), wake.future]);
    } finally {
      _wakes.remove(wake);
      _cancelSleepTimers();
    }
  }

  /// Free the overlap locks that timed-out runs still hold. Call it when
  /// the process ends, so the next process can run those tasks. [work]
  /// calls it after a stop.
  Future<void> close() async {
    for (CacheLock lock in List<CacheLock>.of(_lateLocks)) {
      _lateLocks.remove(lock);
      await _release(lock);
    }
  }

  /// Remove the `withoutOverlapping()` lock of each task, whoever holds
  /// it. Gives the names of the tasks whose lock was there.
  ///
  /// A crash leaves the lock in the store, so the task is skipped until
  /// the lock expires (24 hours by default). This frees it at once.
  /// It removes only the exact lock key of each task, never other keys.
  /// The once-per-tick locks are not touched: each one is for one minute
  /// only, and it expires in 10 minutes.
  ///
  /// Do not call it while a task really runs in another process. That
  /// task could then start a second time.
  ///
  /// Throws [UnsupportedError] when the store can not remove a lock that
  /// another owner holds.
  Future<List<String>> clearOverlapLocks() async {
    List<String> cleared = <String>[];
    for (ScheduledTask task in tasks) {
      // ponytail: every task; a task that dropped
      // withoutOverlapping() can still have an old lock
      if (await store.lock(_lockName('overlap', task)).forceRelease()) {
        cleared.add(task.name);
      }
    }
    return cleared;
  }

  /// Stop [work]: no new task starts. Running tasks can finish.
  void stop() {
    _stopping = true;
    for (Completer<void> wake in _wakes) {
      if (!wake.isCompleted) wake.complete();
    }
  }

  /// Run `clock.sleep` in a zone that keeps its timers, so [work] can
  /// cancel them. `sleep` keeps its old signature, so custom clocks work.
  Future<void> _sleep(Duration duration) {
    ZoneSpecification spec = ZoneSpecification(createTimer: _keepTimer);
    return runZoned(() => clock.sleep(duration), zoneSpecification: spec);
  }

  // ponytail: only one-shot timers; a periodic timer in a custom sleep is not kept
  Timer _keepTimer(
    Zone self,
    ZoneDelegate parent,
    Zone zone,
    Duration duration,
    void Function() callback,
  ) {
    Timer timer = parent.createTimer(zone, duration, callback);
    _sleepTimers.add(timer);
    return timer;
  }

  void _cancelSleepTimers() {
    for (Timer timer in _sleepTimers) {
      timer.cancel();
    }
    _sleepTimers.clear();
  }

  Future<TaskOutcome> _forget(Future<TaskOutcome> run) async {
    try {
      return await run;
    } finally {
      _running.remove(run);
    }
  }

  Future<TaskOutcome> _run(
    ScheduledTask task,
    DateTime tick,
    bool force,
  ) async {
    CacheLock? overlap;
    try {
      if (!force && !await _mayRun(task, tick)) return TaskOutcome.skipped;
      Duration? overlapTtl = task.overlapExpiresAfter;
      if (!force && overlapTtl != null) {
        CacheLock lock = store.lock(_lockName('overlap', task), overlapTtl);
        if (!await lock.get()) {
          _log(
            SchedulerLogLevel.info,
            'skip ${task.name}: the last run still runs',
            'skipped ${task.name}: the last run still runs',
          );
          return TaskOutcome.skipped;
        }
        overlap = lock;
      }
    } catch (error, stack) {
      // a filter or the lock store threw
      _log(
        SchedulerLogLevel.danger,
        'fail ${task.name}: $error',
        'failed ${task.name}: $error',
      );
      await _failed(task, error, stack);
      return TaskOutcome.failed;
    }
    Stopwatch watch = Stopwatch()..start();
    _log(SchedulerLogLevel.info, 'run ${task.name}', 'running ${task.name}');
    bool workEnded = true;
    Future<void>? ended;
    try {
      for (TaskCallback hook in task.beforeHooks) {
        try {
          await hook();
        } on PingException catch (error) {
          // a failed ping never fails the task
          _log(
            SchedulerLogLevel.warn,
            '${task.name}: $error',
            '${task.name}: $error',
          );
        }
      }
      Future<void> work = Future<void>.sync(task.callback);
      workEnded = false;
      // never throws: it only tells when the work really ends
      ended = work.then<void>(
        (_) => workEnded = true,
        onError: (Object _) => workEnded = true,
      );
      Duration? limit = task.timeoutAfter;
      await (limit == null ? work : work.timeout(limit));
      int ms = watch.elapsedMilliseconds;
      _log(
        SchedulerLogLevel.success,
        'done ${task.name} ($ms ms)',
        'ran ${task.name} in ${ms}ms',
      );
      await _hooks(task, task.successHooks);
      return TaskOutcome.ran;
    } catch (error, stack) {
      int ms = watch.elapsedMilliseconds;
      _log(
        SchedulerLogLevel.danger,
        'fail ${task.name} ($ms ms): $error',
        'failed ${task.name} in ${ms}ms: $error',
      );
      await _failed(task, error, stack);
      return TaskOutcome.failed;
    } finally {
      await _hooks(task, task.afterHooks);
      await _releaseWhenEnded(overlap, workEnded ? null : ended);
    }
  }

  /// Free [lock] now, or when [ended] completes. A timed-out run keeps
  /// its work going, so `withoutOverlapping()` keeps the lock until then.
  /// The lock always has a ttl, so a hung task frees it at the ttl.
  Future<void> _releaseWhenEnded(CacheLock? lock, Future<void>? ended) async {
    if (lock == null) return;
    if (ended == null) return _release(lock);
    _lateLocks.add(lock);
    unawaited(
      ended.then((_) {
        if (_lateLocks.remove(lock)) return _release(lock);
      }),
    );
  }

  /// filters, then the once-per-tick lock
  Future<bool> _mayRun(ScheduledTask task, DateTime tick) async {
    if (!await task.filtersPass()) return false;
    if (!task.oneServer) return true;
    String name = '${_lockName('tick', task)}:${tick.millisecondsSinceEpoch}';
    // never released: a late runner must not run this tick again
    return store.lock(name, ScheduleConstants.tickLockTtl).get();
  }

  Future<void> _hooks(ScheduledTask task, List<TaskCallback> hooks) async {
    for (TaskCallback hook in hooks) {
      try {
        await hook();
      } catch (error) {
        _log(
          SchedulerLogLevel.danger,
          'hook of ${task.name} failed: $error',
          'hook of ${task.name} failed: $error',
        );
      }
    }
  }

  Future<void> _failed(ScheduledTask task, Object error, StackTrace s) async {
    for (TaskErrorHook hook in task.failureHooks) {
      try {
        await hook(error, s);
      } catch (hookError) {
        _log(
          SchedulerLogLevel.danger,
          'onFailure hook of ${task.name} failed: $hookError',
          'onFailure hook of ${task.name} failed: $hookError',
        );
      }
    }
  }

  Future<void> _release(CacheLock? lock) async {
    if (lock == null) return;
    try {
      await lock.release();
    } catch (error) {
      _log(
        SchedulerLogLevel.warn,
        'lock ${lock.name} not released: $error',
        'lock ${lock.name} not released: $error',
      );
    }
  }

  String _lockName(String kind, ScheduledTask task) {
    return '${ScheduleConstants.lockPrefix}$kind:${task.name}';
  }

  /// Write [line] to [out] as before, and [message] to the Logger.
  void _log(SchedulerLogLevel level, String line, String message) {
    SchedulerLog.write(
      out,
      flags,
      level,
      '[schedule] ${clock.now().toIso8601String()} $line',
      message,
    );
  }
}
