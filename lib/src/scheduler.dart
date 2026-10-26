import 'dart:async';

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
  }) : out = out ?? StringBuffer();

  final List<ScheduledTask> tasks;

  /// The lock store. Share it (Redis) between servers.
  final CacheStore store;

  final ScheduleClock clock;

  /// Log lines go here.
  final StringSink out;

  /// Running tasks, so a stop can wait for them.
  final Set<Future<TaskOutcome>> _running = <Future<TaskOutcome>>{};

  bool _stopping = false;
  final Completer<void> _stopSignal = Completer<void>();

  /// The cache store for the locks: [name] of [manager], or the default
  /// store. A store without locks (file, null) gives a memory store.
  static CacheStore lockStore(CacheManager manager, String? name) {
    CacheStore store = manager.store(name);
    try {
      store.lock(ScheduleConstants.lockPrefix);
      return store;
    } on UnsupportedError {
      return CacheStore(MemoryDriver());
    }
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
    while (!_stopping) {
      DateTime now = clock.now();
      DateTime next = minuteOf(now).add(const Duration(minutes: 1));
      await Future.any(<Future<void>>[
        clock.sleep(next.difference(now)),
        _stopSignal.future,
      ]);
      if (_stopping) break;
      // after a long pause (sleeping laptop) run the minute of now
      DateTime late = minuteOf(clock.now());
      await runDue(tick: late.isAfter(next) ? late : next);
    }
    await idle();
  }

  /// Stop [work]: no new task starts. Running tasks can finish.
  void stop() {
    _stopping = true;
    if (!_stopSignal.isCompleted) _stopSignal.complete();
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
    try {
      for (TaskCallback hook in task.beforeHooks) {
        await hook();
      }
      Future<void> work = Future<void>.sync(task.callback);
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
      await _release(overlap);
    }
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
