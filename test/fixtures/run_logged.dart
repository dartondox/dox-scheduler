import 'dart:io';

import 'package:dox_core/dox_core.dart';
import 'package:dox_scheduler/dox_scheduler.dart';

import '../fake_clock.dart';

/// `run` with the Logger on, and stdout and stderr as the sinks.
Future<void> main(List<String> args) async {
  Dox().config = AppConfig(
    appKey: 'x',
    logger: LoggerConfig(enabled: true, prettyPrint: true),
  );
  exitCode = await SchedulerRunner(
    schedule: (Schedule s) => s.call('a', () {}),
    clock: FakeClock(DateTime.utc(2026, 10, 25)),
  ).run(<String>['run']);
}
