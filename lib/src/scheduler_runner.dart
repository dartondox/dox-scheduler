import 'dart:async';
import 'dart:io';

import 'package:dox_cache/dox_cache.dart' show MemoryDriver;
import 'package:dox_core/dox_core.dart';

import 'constants/schedule_constants.dart';
import 'schedule.dart';
import 'schedule_config.dart';
import 'scheduled_task.dart';
import 'scheduler.dart';
import 'scheduler_provider.dart';

/// The command line of `bin/schedule.dart`:
/// ```
/// Future<void> main(List<String> args) async {
///   exitCode = await SchedulerRunner(
///     schedule: schedule,
///     app: appConfig,
///     config: scheduleConfig,
///   ).run(args);
/// }
/// ```
/// Commands: `work` (default), `run`, `list`, `test <name>`,
/// `clear-cache`.
class SchedulerRunner {
  SchedulerRunner({
    required this.schedule,
    this.app,
    this.config = const ScheduleConfig(),
    this.clock = const ScheduleClock(),
    this.store,
    StringSink? out,
  }) : out = out ?? stdout;

  /// Your function that adds the tasks.
  final void Function(Schedule s) schedule;

  /// The app config. When set, the runner starts the app providers (like
  /// the database) and the cache stores before the tasks run.
  final AppConfig? app;

  final ScheduleConfig config;

  final ScheduleClock clock;

  /// The lock store. Default: `config.store` of the app cache.
  final CacheStore? store;

  /// Output.
  final StringSink out;

  static const String usage = '''
Usage: dart run bin/schedule.dart <command>

  work         run due tasks at every minute, until Ctrl+C (default)
  run          run the tasks due this minute once, then exit (for cron)
  list         show each task, its schedule and next run time
  test <name>  run one task now
  clear-cache  remove the withoutOverlapping() locks left by a crash''';

  /// Run the command of [args]. Gives the exit code.
  Future<int> run(List<String> args) async {
    String command = args.isEmpty ? 'work' : args.first;
    Schedule s = Schedule(timezone: config.timezone);
    schedule(s);
    switch (command) {
      case 'list':
        _list(s.tasks);
        return 0;
      case 'work':
        return _withApp(s, _work);
      case 'run':
        return _withApp(s, _runOnce);
      case 'test':
        if (args.length < 2) break;
        ScheduledTask? task = s.find(args[1]);
        if (task == null) {
          out.writeln('No task named "${args[1]}". Run `list` to see them.');
          return 1;
        }
        _testTask = task;
        return _withApp(s, _test);
      case 'clear-cache':
        return _withApp(s, _clearCache);
    }
    out.writeln(usage);
    return ScheduleConstants.usageExitCode;
  }

  ScheduledTask? _testTask;

  Future<int> _work(Scheduler scheduler) async {
    List<StreamSubscription<ProcessSignal>> signals =
        <StreamSubscription<ProcessSignal>>[];
    void onSignal(ProcessSignal signal) {
      out.writeln('[schedule] $signal: stopping, running tasks can finish');
      // the next signal does the default: it ends the process
      for (StreamSubscription<ProcessSignal> sub in signals) {
        sub.cancel();
      }
      scheduler.stop();
    }

    signals.add(ProcessSignal.sigint.watch().listen(onSignal));
    if (!Platform.isWindows) {
      signals.add(ProcessSignal.sigterm.watch().listen(onSignal));
    }
    out.writeln('[schedule] working, ${scheduler.tasks.length} tasks');
    await scheduler.work();
    for (StreamSubscription<ProcessSignal> sub in signals) {
      await sub.cancel();
    }
    return 0;
  }

  /// With a due sub-minute task, `run` repeats it until the
  /// minute ends. Else it ends at once, like before.
  Future<int> _runOnce(Scheduler scheduler) async {
    DateTime minute = Scheduler.minuteOf(clock.now());
    Map<String, TaskOutcome> outcomes = await scheduler.runDue(
      tick: minute,
      waitForBackground: true,
    );
    Map<String, TaskOutcome> repeats = await scheduler.runRepeats(
      minute,
      waitForBackground: true,
    );
    bool failed =
        outcomes.containsValue(TaskOutcome.failed) ||
        repeats.containsValue(TaskOutcome.failed);
    return failed ? 1 : 0;
  }

  Future<int> _test(Scheduler scheduler) async {
    TaskOutcome outcome = await scheduler.runTask(
      _testTask!,
      clock.now(),
      force: true,
    );
    return outcome == TaskOutcome.failed ? 1 : 0;
  }

  /// Remove the `withoutOverlapping()` locks.
  /// Do not run it while a task really runs in
  /// another process: that task could then start twice.
  Future<int> _clearCache(Scheduler scheduler) async {
    List<String> cleared;
    try {
      cleared = await scheduler.clearOverlapLocks();
    } on UnsupportedError catch (error) {
      out.writeln('The lock store can not remove the locks: ${error.message}');
      return 1;
    }
    if (cleared.isEmpty) {
      out.writeln('No overlap locks found. Nothing to clear.');
    }
    for (String name in cleared) {
      out.writeln('Removed the overlap lock of $name.');
    }
    return 0;
  }

  void _list(List<ScheduledTask> tasks) {
    if (tasks.isEmpty) {
      out.writeln('No tasks. Add them in lib/config/schedule.dart.');
      return;
    }
    DateTime now = clock.now();
    int nameWidth = 4;
    int cronWidth = 8;
    for (ScheduledTask task in tasks) {
      if (task.name.length > nameWidth) nameWidth = task.name.length;
      int width = _schedule(task).length;
      if (width > cronWidth) cronWidth = width;
    }
    out.writeln(
      '${'Task'.padRight(nameWidth)}  ${'Schedule'.padRight(cronWidth)}  '
      'Next run',
    );
    for (ScheduledTask task in tasks) {
      DateTime? next = task.nextRun(now);
      String when = next == null ? 'never' : _format(task, next);
      out.writeln(
        '${task.name.padRight(nameWidth)}  '
        '${_schedule(task).padRight(cronWidth)}  $when',
      );
    }
  }

  /// the cron text and the filters, like
  /// `0 * * * *, between 09:00-17:00, env production`
  static String _schedule(ScheduledTask task) {
    String filters = task.describeFilters();
    return filters.isEmpty ? task.describe() : '${task.describe()}, $filters';
  }

  /// like `2026-10-26 02:00 UTC` or `2026-10-26 02:00 Asia/Yangon`
  String _format(ScheduledTask task, DateTime moment) {
    String wall = task.zone.wall(moment).toIso8601String();
    return '${wall.substring(0, 10)} ${wall.substring(11, 16)} '
        '${task.zone.name}';
  }

  /// start the app, run [command], stop the app
  Future<int> _withApp(
    Schedule s,
    Future<int> Function(Scheduler scheduler) command,
  ) async {
    List<DoxProvider> providers = await _startApp();
    try {
      Scheduler scheduler = Scheduler(
        tasks: s.tasks,
        store: store ?? _defaultStore(),
        clock: clock,
        out: out,
      );
      try {
        return await command(scheduler);
      } finally {
        // the process ends: free the locks of timed-out runs
        await scheduler.close();
      }
    } finally {
      await _stopApp(providers);
    }
  }

  Future<List<DoxProvider>> _startApp() async {
    AppConfig? appConfig = app;
    if (appConfig == null) return <DoxProvider>[];
    Dox().initialize(appConfig);
    List<DoxProvider> providers = <DoxProvider>[];
    Set<Type> seen = <Type>{};
    for (DoxProvider provider in <DoxProvider>[
      ...appConfig.providers,
      ...Dox().ioc.providers,
    ]) {
      // this command is the scheduler: do not start a second one
      if (provider is SchedulerProvider || !seen.add(provider.runtimeType)) {
        continue;
      }
      try {
        await provider.setup();
      } catch (_) {
        await _undoStart(providers);
        rethrow;
      }
      providers.add(provider);
    }
    // after every setup(), like the web server: eg. the in-process
    // queue worker of dox_queue starts here
    try {
      for (DoxProvider provider in providers) {
        await provider.boot();
      }
    } catch (_) {
      await _undoStart(providers);
      rethrow;
    }
    return providers;
  }

  /// A setup threw: shut down the [started] providers in reverse order.
  /// Their errors are logged, so the setup error is the one thrown.
  Future<void> _undoStart(List<DoxProvider> started) async {
    for (DoxProvider provider in started.reversed) {
      try {
        await provider.shutdown();
      } catch (error) {
        out.writeln(
          '[schedule] shutdown of ${provider.runtimeType} failed: '
          '$error',
        );
      }
    }
    try {
      await Dox().cache.close();
    } catch (error) {
      out.writeln('[schedule] cache not closed: $error');
    }
  }

  Future<void> _stopApp(List<DoxProvider> providers) async {
    for (DoxProvider provider in providers) {
      await provider.shutdown();
    }
    if (app != null) await Dox().cache.close();
  }

  /// the app cache store, or memory when there is no app
  CacheStore _defaultStore() {
    if (app == null) return CacheStore(MemoryDriver());
    return Scheduler.lockStore(Dox().cache, config.store);
  }
}
