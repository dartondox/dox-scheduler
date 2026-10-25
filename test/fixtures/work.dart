import 'dart:io';

import 'package:dox_scheduler/dox_scheduler.dart';

import '../fake_clock.dart';

/// `work` with a fast fake clock. The task takes 300 ms of real time.
void schedule(Schedule s) {
  s.call('slow', slow).withoutOverlapping();
}

Future<void> slow() async {
  stdout.writeln('started');
  await Future<void>.delayed(const Duration(milliseconds: 300));
  stdout.writeln('finished');
}

Future<void> main(List<String> args) async {
  exitCode = await SchedulerRunner(
    schedule: schedule,
    clock: FakeClock(DateTime.utc(2026, 10, 25)),
  ).run(args);
}
