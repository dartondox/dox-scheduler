import 'dart:io';

import 'package:dox_scheduler/dox_scheduler.dart';

/// `work` with the real clock, so it sleeps until the next full minute.
void schedule(Schedule s) {
  s.call('noop', noop).everyMinute();
}

void noop() {}

Future<void> main(List<String> args) async {
  exitCode = await SchedulerRunner(schedule: schedule).run(args);
}
