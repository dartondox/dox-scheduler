import 'dart:async';
import 'dart:io';

import 'package:dox_cache/dox_cache.dart';

import 'constants/schedule_constants.dart';
import 'scheduled_task.dart';

/// Gives the time and waits. Inject a fake one in tests to move time.
class ScheduleClock {
  const ScheduleClock();

  /// The time now, in UTC.
  DateTime now() {
    return DateTime.now().toUtc();
  }

  /// Wait for [duration].
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
  }) : out = out ?? StringBuffer(),
       err = err ?? stderr;

  final List<ScheduledTask> tasks;

  /// The lock store. Share it (Redis) between servers.
  final CacheStore store;

  final ScheduleClock clock;

  /// Log lines go here.
  final StringSink out;

  /// Warnings go here. Default: stderr.
  final StringSink err;

  bool _lockChecked = false;

  /// Running tasks, so a stop can wait for them.
  final Set<Future<TaskOutcome>> _running = <Future<TaskOutcome>>{};

  /// Overlap locks of timed-out runs whose work still goes on.
  final Set<CacheLock> _lateLocks = <CacheLock>{};

  bool _stopping = false;
  final Completer<void> _stopSignal = Completer<void>();

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
  /// `runDue` and `work` call it.
  void warnIfLockNotShared() {
    if (_lockChecked) return;
    _lockChecked = true;
    CacheDriver driver = store.driver;
    // ponytail: only the drivers we know are local; a custom driver may be shared
    if (driver is! MemoryDriver && driver is! FileDriver) return;
    bool oneServer = false;
    for (ScheduledTask task in tasks) {
      if (task.oneServer) oneServer = true;
    }
    if (!oneServer) return;
    String kind = driver is FileDriver ? 'file' : 'memory';
    err.writeln(
      '[schedule] warning: the lock store is a $kind store. It is not '
      'shared between servers, so onOneServer() works only inside one '
      'server. When many servers run the schedule, each server runs the '
      "task. Use a Redis cache store: ScheduleConfig(store: 'redis').",
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
    Map<String, TaskOutcome> outcomes = <String, TaskOutcome>{};
    Map<String, Future<TaskOutcome>> background =
        <String, Future<TaskOutcome>>{};
    for (ScheduledTask task in tasks) {
      if (_stopping) break;
      if (!task.isDue(minute)) continue;
      Future<TaskOutcome> run = runTask(task, minute);
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

  /// Run [task] for the minute [tick]: filters, locks, hooks and the
  /// work. With [force] (the `test` command) the filters and locks are
  /// not checked.
  Future<TaskOutcome> runTask(
    ScheduledTask task,
    DateTime tick, {
    bool force = false,
  }) {
    Future<TaskOutcome> run = _run(task, minuteOf(tick), force);
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
  /// tick is the next full minute. After [stop] it waits for the
  /// running tasks.
  Future<void> work() async {
    warnIfLockNotShared();
    while (!_stopping) {
      DateTime now = clock.now();
      DateTime next = minuteOf(now).add(const Duration(minutes: 1));
      await Future.any(<Future<void>>[
        _sleep(next.difference(now)),
        _stopSignal.future,
      ]);
      _cancelSleepTimers();
      if (_stopping) break;
      // after a long pause (sleeping laptop) run the minute of now
      DateTime late = minuteOf(clock.now());
      await runDue(tick: late.isAfter(next) ? late : next);
    }
    await idle();
    await close();
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

  /// Stop [work]: no new task starts. Running tasks can finish.
  void stop() {
    _stopping = true;
    if (!_stopSignal.isCompleted) _stopSignal.complete();
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
          _log('skip ${task.name}: the last run still runs');
          return TaskOutcome.skipped;
        }
        overlap = lock;
      }
    } catch (error, stack) {
      // a filter or the lock store threw
      _log('fail ${task.name}: $error');
      await _failed(task, error, stack);
      return TaskOutcome.failed;
    }
    Stopwatch watch = Stopwatch()..start();
    _log('run ${task.name}');
    bool workEnded = true;
    Future<void>? ended;
    try {
      for (TaskCallback hook in task.beforeHooks) {
        await hook();
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
      _log('done ${task.name} (${watch.elapsedMilliseconds} ms)');
      await _hooks(task, task.successHooks);
      return TaskOutcome.ran;
    } catch (error, stack) {
      _log('fail ${task.name} (${watch.elapsedMilliseconds} ms): $error');
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
        _log('hook of ${task.name} failed: $error');
      }
    }
  }

  Future<void> _failed(ScheduledTask task, Object error, StackTrace s) async {
    for (TaskErrorHook hook in task.failureHooks) {
      try {
        await hook(error, s);
      } catch (hookError) {
        _log('onFailure hook of ${task.name} failed: $hookError');
      }
    }
  }

  Future<void> _release(CacheLock? lock) async {
    if (lock == null) return;
    try {
      await lock.release();
    } catch (error) {
      _log('lock ${lock.name} not released: $error');
    }
  }

  String _lockName(String kind, ScheduledTask task) {
    return '${ScheduleConstants.lockPrefix}$kind:${task.name}';
  }

  void _log(String line) {
    out.writeln('[schedule] ${clock.now().toIso8601String()} $line');
  }
}
