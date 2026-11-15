import 'package:dox_cache/dox_cache.dart';
import 'package:dox_scheduler/dox_scheduler.dart';
import 'package:dox_scheduler/src/bounded_sink.dart';
import 'package:test/test.dart';

import 'fake_clock.dart';

class CountingTask extends ScheduledTask {
  CountingTask() : super('count', () {});

  int calls = 0;

  @override
  bool isDue(DateTime tick) {
    calls++;
    return super.isDue(tick);
  }
}

void main() {
  test('isDue runs once per minute, not once per sub-minute step', () async {
    DateTime minute = DateTime.utc(2026, 10, 25, 2);
    CountingTask task = CountingTask()..everyFiveSeconds();
    Scheduler scheduler = Scheduler(
      tasks: <ScheduledTask>[task],
      store: CacheStore(MemoryDriver()),
      clock: FakeClock(minute),
      err: StringBuffer(),
    );
    await scheduler.runDue(tick: minute);
    await scheduler.runRepeats(minute);
    expect(task.calls, 1);
  });

  group('BoundedSink |', () {
    test('keeps the last characters only', () {
      BoundedSink sink = BoundedSink(limit: 10);
      for (int i = 0; i < 100; i++) {
        sink.writeln('line $i');
      }
      String text = sink.toString();
      expect(text.length, 10);
      expect(text.endsWith('line 99\n'), isTrue);
    });

    test('short text stays whole', () {
      BoundedSink sink = BoundedSink();
      sink.write('a');
      sink.writeAll(<String>['b', 'c'], '-');
      sink.writeCharCode(100);
      sink.writeln();
      expect(sink.toString(), 'ab-cd\n');
    });

    test('writeAll also trims', () {
      BoundedSink sink = BoundedSink(limit: 10);
      sink.writeAll(List<String>.filled(100, 'abc'), ',');
      expect(sink.toString().length, 10);
      expect(sink.toString().endsWith('abc'), isTrue);
    });

    test('a cut in a surrogate pair drops the broken half', () {
      // each emoji is 2 code units; limit 5 cuts one pair in half
      BoundedSink sink = BoundedSink(limit: 5);
      sink.write('\u{1F600}' * 20);
      String text = sink.toString();
      expect(text.length, 4);
      expect(text, '\u{1F600}' * 2);
      BoundedSink big = BoundedSink(limit: 5);
      big.writeAll(List<String>.filled(20, '\u{1F600}'));
      expect(big.toString(), '\u{1F600}' * 2);
    });

    test('default out of Scheduler is bounded', () {
      Scheduler scheduler = Scheduler(
        tasks: <ScheduledTask>[],
        store: CacheStore(MemoryDriver()),
      );
      expect(scheduler.out, isA<BoundedSink>());
    });
  });

  group('isDue cache |', () {
    DateTime minute = DateTime.utc(2026, 10, 25, 2);

    Scheduler make(CountingTask task, FakeClock clock) {
      return Scheduler(
        tasks: <ScheduledTask>[task],
        store: CacheStore(MemoryDriver()),
        clock: clock,
        err: StringBuffer(),
      );
    }

    test('a new minute gives a fresh answer', () async {
      CountingTask task = CountingTask()..everyFiveSeconds();
      Scheduler scheduler = make(task, FakeClock(minute));
      await scheduler.runDue(tick: minute);
      await scheduler.runDue(tick: minute.add(const Duration(minutes: 1)));
      expect(task.calls, 2);
    });

    test('a late minute uses that minute as the key', () async {
      CountingTask task = CountingTask()..everyFiveSeconds();
      Scheduler scheduler = make(task, FakeClock(minute));
      await scheduler.runDue(tick: minute);
      DateTime late = minute.add(const Duration(minutes: 3));
      await scheduler.runDue(tick: late);
      await scheduler.runRepeats(late);
      expect(task.calls, 2);
    });

    test('a task added after the first check is still checked', () async {
      CountingTask first = CountingTask()..everyFiveSeconds();
      CountingTask second = CountingTask()..everyFiveSeconds();
      Scheduler scheduler = make(first, FakeClock(minute));
      await scheduler.runDue(tick: minute);
      scheduler.tasks.add(second);
      await scheduler.runRepeats(minute);
      expect(first.calls, 1);
      expect(second.calls, 1);
    });
  });
}
