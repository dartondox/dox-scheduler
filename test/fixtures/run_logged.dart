import 'dart:io';

import 'package:dox_core/dox_core.dart';
import 'package:dox_scheduler/dox_scheduler.dart';

import '../fake_clock.dart';

/// `run` with stdout and stderr as the sinks. The arg picks the case:
/// - `off`: the Logger is on, the flag is off.
/// - `on`: the Logger and the flag are on.
/// - `warn`: like `on`, with the Logger level `warn`.
/// - `no-config`: the flag is on, but `Dox().config` is not set.
Future<void> main(List<String> args) async {
  String mode = args.first;
  if (mode != 'no-config') {
    Dox().config = AppConfig(
      appKey: 'x',
      logger: LoggerConfig(
        enabled: true,
        prettyPrint: true,
        level: mode == 'warn' ? 'warn' : 'info',
      ),
    );
  }
  exitCode = await SchedulerRunner(
    schedule: (Schedule s) => s.call('a', () {}),
    clock: FakeClock(DateTime.utc(2026, 10, 25)),
    config: ScheduleConfig(flags: SchedulerFlags(loggerLines: mode != 'off')),
  ).run(<String>['run']);
}
