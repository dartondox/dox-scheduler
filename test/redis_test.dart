import 'dart:io';

import 'package:dox_cache/dox_cache.dart';
import 'package:dox_scheduler/dox_scheduler.dart';
import 'package:test/test.dart';

import 'fake_clock.dart';

/// Runs when REDIS_PORT is set (CI starts Redis). REDIS_HOST is optional.
String? port = Platform.environment['REDIS_PORT'];

CacheStore redis() {
  return CacheStore(
    const RedisDriverFactory().create(<String, dynamic>{
      'driver': 'redis',
      'host': Platform.environment['REDIS_HOST'] ?? '127.0.0.1',
      'port': int.parse(port!),
      'prefix': 'dox_scheduler_test:',
    }),
  );
}

void main() {
  DateTime tick = DateTime.utc(2026, 10, 25, 2);

  group('Redis |', () {
    late CacheStore one;
    late CacheStore two;

    setUp(() async {
      // two connections, like two servers
      one = redis();
      two = redis();
      await one.flush();
    });

    tearDown(() async {
      await one.flush();
      await one.driver.close();
      await two.driver.close();
    });

    test('once per tick across two servers', () async {
      int runs = 0;
      Schedule s = Schedule();
      s.call('a', () => runs++);
      Scheduler a = Scheduler(
        tasks: s.tasks,
        store: one,
        clock: FakeClock(tick),
      );
      Scheduler b = Scheduler(
        tasks: s.tasks,
        store: two,
        clock: FakeClock(tick),
      );
      await Future.wait(<Future<Map<String, TaskOutcome>>>[
        a.runDue(tick: tick),
        b.runDue(tick: tick),
      ]);
      expect(runs, 1);
      // a late server on the same tick does not run it again
      await b.runDue(tick: tick);
      expect(runs, 1);
      await b.runDue(tick: tick.add(const Duration(minutes: 1)));
      expect(runs, 2);
    });

    test('withoutOverlapping across two servers', () async {
      int runs = 0;
      Schedule s = Schedule();
      ScheduledTask task = s
          .call('a', () async {
            runs++;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          })
          .withoutOverlapping()
          .onEveryServer();
      Scheduler a = Scheduler(tasks: s.tasks, store: one);
      Scheduler b = Scheduler(tasks: s.tasks, store: two);
      Future<TaskOutcome> first = a.runTask(task, tick);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await b.runTask(task, tick), TaskOutcome.skipped);
      expect(await first, TaskOutcome.ran);
      expect(await b.runTask(task, tick), TaskOutcome.ran);
      expect(runs, 2);
    });
  }, skip: port == null ? 'set REDIS_PORT to run the Redis tests' : null);
}
