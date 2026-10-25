import 'package:dox_scheduler/dox_scheduler.dart';

/// A clock that only moves when the scheduler sleeps.
class FakeClock extends ScheduleClock {
  FakeClock(this.time);

  DateTime time;

  int sleeps = 0;

  @override
  DateTime now() {
    return time;
  }

  @override
  Future<void> sleep(Duration duration) async {
    sleeps++;
    time = time.add(duration);
    await Future<void>.delayed(Duration.zero);
  }
}
