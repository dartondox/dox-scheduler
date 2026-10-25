import 'dart:async';

import 'package:dox_cache/dox_cache.dart';
import 'package:dox_scheduler/dox_scheduler.dart';
import 'package:test/test.dart';

import 'fake_clock.dart';

/// 02:00 UTC
final DateTime tick = DateTime.utc(2026, 10, 25, 2);

Scheduler make(Schedule s, {CacheStore? store, FakeClock? clock}) {
  return Scheduler(
    tasks: s.tasks,
    store: store ?? CacheStore(MemoryDriver()),
    clock: clock ?? FakeClock(tick),
  );
}

void main() {
  group('runDue |', () {
    test('runs only due tasks, in order', () async {
      List<String> ran = <String>[];
      Schedule s = Schedule();
      s.call('a', () => ran.add('a')).dailyAt('02:00');
      s.call('b', () => ran.add('b')).dailyAt('03:00');
      s.call('c', () async => ran.add('c')).hourly();
      Map<String, TaskOutcome> out = await make(s).runDue(tick: tick);
      expect(ran, <String>['a', 'c']);
      expect(out, <String, TaskOutcome>{
        'a': TaskOutcome.ran,
        'c': TaskOutcome.ran,
      });
    });

    test('uses the clock and ignores seconds', () async {
      int runs = 0;
      Schedule s = Schedule();
      s.call('a', () => runs++).dailyAt('02:00');
      await make(
        s,
        clock: FakeClock(tick.add(const Duration(seconds: 42))),
      ).runDue();
      expect(runs, 1);
    });

    test('a failure does not stop the next task', () async {
      List<String> ran = <String>[];
      Schedule s = Schedule();
      s.call('bad', () => throw StateError('boom'));
      s.call('good', () => ran.add('good'));
      Map<String, TaskOutcome> out = await make(s).runDue(tick: tick);
      expect(out['bad'], TaskOutcome.failed);
      expect(out['good'], TaskOutcome.ran);
    });

    test('filters skip', () async {
      Schedule s = Schedule();
      s.call('a', () {}).when(() => false);
      s.call('b', () {}).skip(() => true);
      Map<String, TaskOutcome> out = await make(s).runDue(tick: tick);
      expect(out['a'], TaskOutcome.skipped);
      expect(out['b'], TaskOutcome.skipped);
    });

    test('a throwing filter is a failure', () async {
      Schedule s = Schedule();
      s.call('a', () {}).when(() => throw StateError('db down'));
      expect((await make(s).runDue(tick: tick))['a'], TaskOutcome.failed);
    });

    test('runInBackground does not block the next task', () async {
      Completer<void> gate = Completer<void>();
      List<String> ran = <String>[];
      Schedule s = Schedule();
      s.call('slow', () => gate.future).runInBackground();
      s.call('fast', () => ran.add('fast'));
      Scheduler scheduler = make(s);
      Map<String, TaskOutcome> out = await scheduler.runDue(tick: tick);
      expect(ran, <String>['fast']);
      expect(out.containsKey('slow'), isFalse);
      gate.complete();
      await scheduler.idle();
    });

    test('waitForBackground collects background outcomes', () async {
      Schedule s = Schedule();
      s.call('bg', () async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        throw StateError('late');
      }).runInBackground();
      Map<String, TaskOutcome> out = await make(s)
          .runDue(tick: tick, waitForBackground: true);
      expect(out['bg'], TaskOutcome.failed);
    });

    test('timeout fails the run', () async {
      Schedule s = Schedule();
      s
          .call('slow', () => Future<void>.delayed(const Duration(seconds: 5)))
          .timeout(const Duration(milliseconds: 10));
      expect((await make(s).runDue(tick: tick))['slow'], TaskOutcome.failed);
    });
  });

  group('hooks |', () {
    test('success order', () async {
      List<String> log = <String>[];
      Schedule s = Schedule();
      s
          .call('a', () => log.add('run'))
          .before(() => log.add('before'))
          .onSuccess(() => log.add('success'))
          .onFailure((Object e, StackTrace st) => log.add('failure'))
          .after(() => log.add('after'));
      await make(s).runDue(tick: tick);
      expect(log, <String>['before', 'run', 'success', 'after']);
    });

    test('failure order and error', () async {
      List<String> log = <String>[];
      Object? seen;
      Schedule s = Schedule();
      s
          .call('a', () => throw StateError('boom'))
          .onSuccess(() => log.add('success'))
          .onFailure((Object e, StackTrace st) {
            seen = e;
            log.add('failure');
          })
          .after(() => log.add('after'));
      await make(s).runDue(tick: tick);
      expect(log, <String>['failure', 'after']);
      expect(seen, isA<StateError>());
    });

    test('a throwing before hook fails the run, work does not run', () async {
      bool ran = false;
      Schedule s = Schedule();
      s.call('a', () => ran = true).before(() => throw StateError('no'));
      expect((await make(s).runDue(tick: tick))['a'], TaskOutcome.failed);
      expect(ran, isFalse);
    });

    test('a throwing after hook does not change the outcome', () async {
      Schedule s = Schedule();
      s.call('a', () {}).after(() => throw StateError('no'));
      expect((await make(s).runDue(tick: tick))['a'], TaskOutcome.ran);
    });
  });

  group('locks |', () {
    test('withoutOverlapping skips while the last run runs', () async {
      Completer<void> gate = Completer<void>();
      int runs = 0;
      Schedule s = Schedule();
      ScheduledTask task = s
          .call('a', () {
            runs++;
            return gate.future;
          })
          .withoutOverlapping()
          .onEveryServer();
      Scheduler scheduler = make(s);
      Future<TaskOutcome> first = scheduler.runTask(task, tick);
      TaskOutcome second = await scheduler.runTask(
        task,
        tick.add(const Duration(minutes: 1)),
      );
      expect(second, TaskOutcome.skipped);
      gate.complete();
      expect(await first, TaskOutcome.ran);
      // the lock is free again
      expect(
        await scheduler.runTask(task, tick.add(const Duration(minutes: 2))),
        TaskOutcome.ran,
      );
      expect(runs, 2);
    });

    test('without the option, runs overlap', () async {
      Completer<void> gate = Completer<void>();
      Schedule s = Schedule();
      ScheduledTask task = s.call('a', () => gate.future);
      Scheduler scheduler = make(s);
      Future<TaskOutcome> first = scheduler.runTask(task, tick);
      Future<TaskOutcome> second = scheduler.runTask(
        task,
        tick.add(const Duration(minutes: 1)),
      );
      gate.complete();
      expect(await first, TaskOutcome.ran);
      expect(await second, TaskOutcome.ran);
    });

    test('once per tick across two runners sharing a store', () async {
      CacheStore store = CacheStore(MemoryDriver());
      int runs = 0;
      void build(Schedule s) {
        s.call('a', () => runs++);
      }

      Schedule s1 = Schedule();
      Schedule s2 = Schedule();
      build(s1);
      build(s2);
      Scheduler one = make(s1, store: store);
      Scheduler two = make(s2, store: store);
      List<Map<String, TaskOutcome>> out = await Future.wait(
        <Future<Map<String, TaskOutcome>>>[
          one.runDue(tick: tick),
          two.runDue(tick: tick),
        ],
      );
      expect(runs, 1);
      expect(<TaskOutcome>[
        out[0]['a']!,
        out[1]['a']!,
      ], unorderedEquals(<TaskOutcome>[TaskOutcome.ran, TaskOutcome.skipped]));
      // the next tick runs again
      await two.runDue(tick: tick.add(const Duration(minutes: 1)));
      expect(runs, 2);
    });

    test('onEveryServer runs on both runners', () async {
      CacheStore store = CacheStore(MemoryDriver());
      int runs = 0;
      Schedule s = Schedule();
      s.call('a', () => runs++).onEveryServer();
      await make(s, store: store).runDue(tick: tick);
      await make(s, store: store).runDue(tick: tick);
      expect(runs, 2);
    });

    test('runTask with force ignores filters and locks', () async {
      int runs = 0;
      Schedule s = Schedule();
      ScheduledTask task = s.call('a', () => runs++).when(() => false);
      Scheduler scheduler = make(s);
      await scheduler.runTask(task, tick, force: true);
      await scheduler.runTask(task, tick, force: true);
      expect(runs, 2);
    });

    test('lockStore falls back to memory for a store without locks', () {
      CacheManager manager = CacheManager(
        const CacheConfig(
          defaultStore: 'none',
          stores: <String, Map<String, dynamic>>{
            'none': <String, dynamic>{'driver': 'null'},
            'memory': <String, dynamic>{'driver': 'memory'},
          },
        ),
      );
      expect(Scheduler.lockStore(manager, null).driver, isA<MemoryDriver>());
      expect(
        Scheduler.lockStore(manager, 'memory'),
        same(manager.store('memory')),
      );
    });
  });

  group('work |', () {
    test('runs at each minute boundary until stop', () async {
      FakeClock clock = FakeClock(tick.add(const Duration(seconds: 30)));
      List<DateTime> seen = <DateTime>[];
      late Scheduler scheduler;
      Schedule s = Schedule();
      s.call('a', () {
        seen.add(clock.now());
        if (seen.length == 3) scheduler.stop();
      });
      scheduler = make(s, clock: clock);
      await scheduler.work();
      expect(seen, <DateTime>[
        tick.add(const Duration(minutes: 1)),
        tick.add(const Duration(minutes: 2)),
        tick.add(const Duration(minutes: 3)),
      ]);
    });

    test('stop waits for the running task', () async {
      Completer<void> gate = Completer<void>();
      bool finished = false;
      late Scheduler scheduler;
      Schedule s = Schedule();
      s.call('a', () async {
        scheduler.stop();
        await gate.future;
        finished = true;
      }).runInBackground();
      scheduler = make(s, clock: FakeClock(tick));
      Future<void> loop = scheduler.work();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(finished, isFalse);
      gate.complete();
      await loop;
      expect(finished, isTrue);
    });

    test('stop while sleeping ends the loop', () async {
      Scheduler scheduler = Scheduler(
        tasks: <ScheduledTask>[],
        store: CacheStore(MemoryDriver()),
      );
      Future<void> loop = scheduler.work();
      scheduler.stop();
      await loop.timeout(const Duration(seconds: 2));
    });
  });

  test('Schedule rejects duplicate and empty names', () {
    Schedule s = Schedule();
    s.call('a', () {});
    expect(() => s.call('a', () {}), throwsArgumentError);
    expect(() => s.call(' ', () {}), throwsArgumentError);
    expect(s.find('a'), isNotNull);
    expect(s.find('b'), isNull);
  });
}
