import 'dart:io';

import 'package:dox_scheduler/dox_scheduler.dart';

/// `work` with a real sleep. The time is always 1 s after a full minute,
/// so `work` always sleeps about 59 s. A stop must not wait for it.
void schedule(Schedule s) {
  s.call('noop', noop).everyMinute();
}

void noop() {}

class StartOfMinuteClock extends ScheduleClock {
  const StartOfMinuteClock();

  @override
  DateTime now() {
    return DateTime.utc(2026, 10, 25, 0, 0, 1);
  }
}

Future<void> main(List<String> args) async {
  exitCode = await SchedulerRunner(
    schedule: schedule,
    clock: const StartOfMinuteClock(),
  ).run(args);
}
