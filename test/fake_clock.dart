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

/// Waits until [done] is true. Fails after 5 s.
Future<void> waitUntil(bool Function() done) async {
  Stopwatch watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > const Duration(seconds: 5)) {
      throw StateError('the condition was not true in 5 s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
