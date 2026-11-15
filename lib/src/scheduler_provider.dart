import 'dart:async';
import 'dart:io';

import 'package:dox_core/dox_core.dart';

import 'schedule.dart';
import 'schedule_config.dart';
import 'scheduler.dart';
import 'scheduler_log.dart';

/// Runs the schedule inside the running Dox app, when
/// `ScheduleConfig(inProcess: true)`. Extend it in your app, so the
/// generated container finds it:
/// ```
/// class ScheduleProvider extends SchedulerProvider {
///   ScheduleProvider() : super(schedule: schedule, config: scheduleConfig);
/// }
/// ```
/// Only the first isolate of the web server runs the tasks. It does not
/// run in `bin/queue.dart`, the scheduler command or tests that do not
/// set `Dox().isWebServer`. The once-per-tick lock keeps
/// many servers from running a task twice (with a Redis store).
class SchedulerProvider extends DoxProvider {
  SchedulerProvider({
    required this.schedule,
    this.config = const ScheduleConfig(),
    this.clock = const ScheduleClock(),
    this.store,
    StringSink? out,
  }) : out = out ?? stdout;

  /// Your function that adds the tasks.
  final void Function(Schedule s) schedule;

  final ScheduleConfig config;

  final ScheduleClock clock;

  /// The lock store. Default: `config.store` of the app cache.
  final CacheStore? store;

  /// Log lines go here.
  final StringSink out;

  /// The running scheduler, or null when it is off.
  Scheduler? scheduler;

  Future<void>? _loop;

  @override
  Future<void> setup() async {
    if (!config.inProcess || scheduler != null) return;
    // only the web server process runs it: `bin/queue.dart` also calls
    // setup() in isolate 1, and must not run the schedule a second time
    if (!Dox().isWebServer || Dox().isolateId != 1) return;
    Schedule s = Schedule(timezone: config.timezone);
    schedule(s);
    Scheduler started = Scheduler(
      tasks: s.tasks,
      store: store ?? Scheduler.lockStore(Dox().cache, config.store),
      clock: clock,
      out: out,
      flags: config.flags,
    );
    scheduler = started;
    SchedulerLog.write(
      out,
      config.flags,
      SchedulerLogLevel.info,
      '[schedule] running in the server, ${s.tasks.length} tasks',
      'running in the server, ${s.tasks.length} tasks',
    );
    _loop = started.work();
  }

  /// Stop the loop and wait for the running tasks.
  @override
  Future<void> shutdown() async {
    scheduler?.stop();
    await _loop;
    scheduler = null;
    _loop = null;
  }
}
