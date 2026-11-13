import 'dart:async';
import 'dart:io';

import 'package:dox_cache/dox_cache.dart';
import 'package:dox_core/dox_core.dart' show Env;
import 'package:dox_scheduler/dox_scheduler.dart';
import 'package:test/test.dart';

import 'clear_cache_cases.dart';
import 'fake_clock.dart';

/// 02:00 UTC
final DateTime tick = DateTime.utc(2026, 10, 25, 2);

Scheduler make(Schedule s, {CacheStore? store, FakeClock? clock}) {
  return Scheduler(
    tasks: s.tasks,
    store: store ?? CacheStore(MemoryDriver()),
    clock: clock ?? FakeClock(tick),
    err: StringBuffer(),
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

    test(
      'a timed-out run keeps the overlap lock until its work ends',
      () async {
        Completer<void> gate = Completer<void>();
        int runs = 0;
        Schedule s = Schedule();
        ScheduledTask task = s
            .call('a', () {
              runs++;
              return gate.future;
            })
            .withoutOverlapping()
            .timeout(const Duration(milliseconds: 10))
            .onEveryServer();
        Scheduler scheduler = make(s);
        expect(await scheduler.runTask(task, tick), TaskOutcome.failed);
        // the work still runs: the next tick must not start a second run
        expect(
          await scheduler.runTask(task, tick.add(const Duration(minutes: 1))),
          TaskOutcome.skipped,
        );
        gate.complete();
        await Future<void>.delayed(Duration.zero);
        expect(
          await scheduler.runTask(task, tick.add(const Duration(minutes: 2))),
          TaskOutcome.ran,
        );
        expect(runs, 2);
      },
    );

    test('close frees the lock of a timed-out run', () async {
      Schedule s = Schedule();
      ScheduledTask task = s
          .call('a', () => Completer<void>().future)
          .withoutOverlapping()
          .timeout(const Duration(milliseconds: 10))
          .onEveryServer();
      Scheduler scheduler = make(s);
      expect(await scheduler.runTask(task, tick), TaskOutcome.failed);
      await scheduler.close();
      expect(
        await scheduler.runTask(task, tick.add(const Duration(minutes: 1))),
        TaskOutcome.failed,
      );
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

  group('clear-cache memory |', () {
    late CacheStore store;
    setUp(() => store = CacheStore(MemoryDriver()));
    clearCacheCases(() => store);
  });

  group('clear-cache file |', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('dox_schedule_clear');
    });
    tearDown(() => dir.delete(recursive: true));
    clearCacheCases(() => CacheStore(FileDriver(directory: dir)));
  });

  group('lock warning |', () {
    Scheduler withStore(Schedule s, CacheStore store, StringBuffer err) {
      return Scheduler(
        tasks: s.tasks,
        store: store,
        clock: FakeClock(tick),
        err: err,
      );
    }

    test('prints once with a file store', () async {
      Directory dir = await Directory.systemTemp.createTemp('dox_schedule');
      addTearDown(() => dir.delete(recursive: true));
      StringBuffer err = StringBuffer();
      Schedule s = Schedule();
      s.call('a', () {});
      Scheduler scheduler = withStore(
        s,
        CacheStore(FileDriver(directory: dir)),
        err,
      );
      await scheduler.runDue(tick: tick);
      await scheduler.runDue(tick: tick.add(const Duration(minutes: 1)));
      expect('warning'.allMatches(err.toString()).length, 1);
      expect(err.toString(), contains('file store'));
      expect(err.toString(), contains("ScheduleConfig(store: 'redis')"));
    });

    test('not printed with a shared store', () async {
      StringBuffer err = StringBuffer();
      Schedule s = Schedule();
      s.call('a', () {});
      // a Redis store; no command is sent, so no Redis server is needed
      CacheStore redis = CacheStore(
        const RedisDriverFactory().create(<String, dynamic>{}),
      );
      addTearDown(redis.driver.close);
      withStore(s, redis, err).warnIfLockNotShared();
      expect(err.toString(), isEmpty);
    });

    test('not printed in development or local', () async {
      addTearDown(() => Env().env.remove('APP_ENV'));
      for (String env in <String>['development', ' Local ']) {
        Env().env['APP_ENV'] = env;
        StringBuffer err = StringBuffer();
        Schedule s = Schedule();
        s.call('a', () {});
        withStore(s, CacheStore(MemoryDriver()), err).warnIfLockNotShared();
        expect(err.toString(), isEmpty);
      }
    });

    test('not printed when no task uses onOneServer', () async {
      StringBuffer err = StringBuffer();
      Schedule s = Schedule();
      s.call('a', () {}).onEveryServer();
      await withStore(s, CacheStore(MemoryDriver()), err).runDue(tick: tick);
      expect(err.toString(), isEmpty);
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

  group('sub-minute |', () {
    test('everyFiveSeconds runs 12 times in a minute', () async {
      FakeClock clock = FakeClock(tick.add(const Duration(seconds: 30)));
      List<DateTime> seen = <DateTime>[];
      late Scheduler scheduler;
      Schedule s = Schedule();
      s.call('fast', () {
        seen.add(clock.now());
        if (seen.length == 12) scheduler.stop();
      }).everyFiveSeconds();
      scheduler = make(s, clock: clock);
      await scheduler.work();
      DateTime minute = tick.add(const Duration(minutes: 1));
      expect(seen, <DateTime>[
        for (int i = 0; i < 60; i += 5) minute.add(Duration(seconds: i)),
      ]);
      // one sleep to the minute, then one per step
      expect(clock.sleeps, 12);
    });

    test('mixed steps run on their own seconds', () async {
      List<String> log = <String>[];
      FakeClock clock = FakeClock(tick);
      Schedule s = Schedule();
      s
          .call('ten', () => log.add('10@${clock.now().second}'))
          .everyTenSeconds();
      s
          .call('thirty', () => log.add('30@${clock.now().second}'))
          .everyThirtySeconds();
      s.call('minute', () => log.add('60@${clock.now().second}'));
      Scheduler scheduler = make(s, clock: clock);
      await scheduler.runDue(tick: tick);
      await scheduler.runRepeats(tick);
      expect(log, <String>[
        '10@0', '30@0', '60@0', '10@10', '10@20', '10@30', '30@30', //
        '10@40', '10@50',
      ]);
      // a step of 10 s: 5 sleeps
      expect(clock.sleeps, 5);
    });

    test('no sub-minute task: one sleep per minute', () async {
      FakeClock clock = FakeClock(tick.add(const Duration(seconds: 30)));
      int runs = 0;
      late Scheduler scheduler;
      Schedule s = Schedule();
      s.call('a', () {
        if (++runs == 3) scheduler.stop();
      });
      scheduler = make(s, clock: clock);
      await scheduler.work();
      expect(clock.sleeps, 3);
      expect(await make(s, clock: clock).runRepeats(tick), isEmpty);
    });

    test('a minute that is not due does not repeat', () async {
      FakeClock clock = FakeClock(tick);
      int runs = 0;
      Schedule s = Schedule();
      s.call('a', () => runs++).everySecond().between('03:00', '04:00');
      Scheduler scheduler = make(s, clock: clock);
      await scheduler.runDue(tick: tick);
      await scheduler.runRepeats(tick);
      expect(runs, 0);
      expect(clock.sleeps, 0);
    });

    test('when() is checked at each repeat', () async {
      FakeClock clock = FakeClock(tick);
      int runs = 0;
      bool open = true;
      Schedule s = Schedule();
      s
          .call('a', () {
            if (++runs == 2) open = false;
          })
          .everyTwentySeconds()
          .when(() => open);
      Scheduler scheduler = make(s, clock: clock);
      await scheduler.runDue(tick: tick);
      Map<String, TaskOutcome> out = await scheduler.runRepeats(tick);
      expect(runs, 2);
      expect(out['a'], TaskOutcome.skipped);
    });

    test('skip() is checked at each repeat', () async {
      FakeClock clock = FakeClock(tick);
      List<int> seconds = <int>[];
      Schedule s = Schedule();
      s
          .call('a', () => seconds.add(clock.now().second))
          .everyFifteenSeconds()
          .skip(() => clock.now().second == 30);
      Scheduler scheduler = make(s, clock: clock);
      await scheduler.runDue(tick: tick);
      await scheduler.runRepeats(tick);
      expect(seconds, <int>[0, 15, 45]);
    });

    test('repeats follow the minutes of a timezone()', () async {
      // 02:00 UTC is 08:30 in Yangon
      FakeClock clock = FakeClock(tick);
      int inside = 0;
      int outside = 0;
      Schedule s = Schedule();
      s
          .call('in', () => inside++)
          .everyTwentySeconds()
          .between('08:30', '08:30')
          .timezone('Asia/Yangon');
      s
          .call('out', () => outside++)
          .everyTwentySeconds()
          .between('02:00', '02:00')
          .timezone('Asia/Yangon');
      Scheduler scheduler = make(s, clock: clock);
      await scheduler.runDue(tick: tick);
      await scheduler.runRepeats(tick);
      expect(inside, 3);
      expect(outside, 0);
    });

    test('withoutOverlapping skips repeats while a run runs', () async {
      Completer<void> gate = Completer<void>();
      FakeClock clock = FakeClock(tick);
      int runs = 0;
      Schedule s = Schedule();
      s
          .call('a', () {
            runs++;
            return runs == 1 ? gate.future : null;
          })
          .everyTenSeconds()
          .withoutOverlapping()
          .runInBackground();
      Scheduler scheduler = make(s, clock: clock);
      await scheduler.runDue(tick: tick);
      Map<String, TaskOutcome> out = await scheduler.runRepeats(
        tick,
        waitForBackground: true,
      );
      expect(out['a'], TaskOutcome.skipped);
      expect(runs, 1);
      gate.complete();
      await scheduler.idle();
      // the lock is free: the next minute runs again
      DateTime next = tick.add(const Duration(minutes: 1));
      clock.time = next;
      await scheduler.runDue(tick: next);
      await scheduler.runRepeats(next);
      await scheduler.idle();
      expect(runs, 7);
    });

    test('a slow run skips the missed steps', () async {
      FakeClock clock = FakeClock(tick);
      List<int> seconds = <int>[];
      Schedule s = Schedule();
      s.call('a', () {
        seconds.add(clock.now().second);
        // the first run takes 12 s
        if (seconds.length == 1) {
          clock.time = clock.time.add(const Duration(seconds: 12));
        }
      }).everyFiveSeconds();
      Scheduler scheduler = make(s, clock: clock);
      await scheduler.runDue(tick: tick);
      await scheduler.runRepeats(tick);
      expect(seconds, <int>[0, 15, 20, 25, 30, 35, 40, 45, 50, 55]);
    });

    test('each step runs once across two runners sharing a store', () async {
      CacheStore store = CacheStore(MemoryDriver());
      int runs = 0;
      Future<void> runMinute() async {
        Schedule s = Schedule();
        s.call('a', () => runs++).everyFifteenSeconds();
        Scheduler scheduler = make(s, store: store, clock: FakeClock(tick));
        await scheduler.runDue(tick: tick);
        await scheduler.runRepeats(tick);
      }

      await runMinute();
      await runMinute();
      expect(runs, 4);
    });

    test('stop in the middle of a minute ends work', () async {
      FakeClock clock = FakeClock(tick);
      int runs = 0;
      late Scheduler scheduler;
      Schedule s = Schedule();
      s.call('a', () {
        if (++runs == 3) scheduler.stop();
      }).everySecond();
      scheduler = make(s, clock: clock);
      await scheduler.work().timeout(const Duration(seconds: 2));
      expect(runs, 3);
    });

    test('stop while sleeping between steps ends work', () async {
      Schedule s = Schedule();
      s.call('a', () {}).everyThirtySeconds();
      // the real clock: the sleep between steps is up to 30 s
      Scheduler scheduler = Scheduler(
        tasks: s.tasks,
        store: CacheStore(MemoryDriver()),
        err: StringBuffer(),
      );
      DateTime minute = Scheduler.minuteOf(DateTime.now().toUtc());
      Future<Map<String, TaskOutcome>> loop = scheduler.runRepeats(minute);
      scheduler.stop();
      await loop.timeout(const Duration(seconds: 2));
    });
  });

  group('exec |', () {
    test('exit code 0 runs, the name is the command line', () async {
      Schedule s = Schedule();
      ScheduledTask task = s.exec('sh', args: <String>['-c', 'exit 0']);
      expect(task.name, 'sh -c exit 0');
      expect((await make(s).runDue(tick: tick))[task.name], TaskOutcome.ran);
    });

    test('a non-zero exit code fails the task', () async {
      Object? seen;
      Schedule s = Schedule();
      ScheduledTask task = s
          .exec('sh', args: <String>['-c', 'exit 3'])
          .onFailure((Object e, StackTrace st) => seen = e);
      expect((await make(s).runDue(tick: tick))[task.name], TaskOutcome.failed);
      expect(seen, isA<ProcessException>());
      expect((seen as ProcessException).errorCode, 3);
    });

    test('a missing executable fails the task', () async {
      Schedule s = Schedule();
      ScheduledTask task = s.exec('dox-no-such-program');
      expect((await make(s).runDue(tick: tick))[task.name], TaskOutcome.failed);
    });

    test('sendOutputTo replaces, appendOutputTo adds', () async {
      Directory dir = await Directory.systemTemp.createTemp('dox_schedule');
      addTearDown(() => dir.delete(recursive: true));
      String path = '${dir.path}/out.log';
      List<String> seen = <String>[];
      Schedule s = Schedule();
      ScheduledTask task = s
          .exec(
            'sh',
            args: <String>['-c', 'echo hi; sleep 0.05; echo oops >&2'],
          )
          .sendOutputTo(path)
          .onOutput(seen.add)
          .onEveryServer();
      Scheduler scheduler = make(s);
      await scheduler.runTask(task, tick);
      await scheduler.runTask(task, tick);
      expect(await File(path).readAsString(), 'hi\noops\n');
      expect(seen, <String>['hi\noops\n', 'hi\noops\n']);
      task.appendOutputTo(path);
      await scheduler.runTask(task, tick);
      expect(await File(path).readAsString(), 'hi\noops\nhi\noops\n');
    });

    test('output is written for a failed process too', () async {
      Directory dir = await Directory.systemTemp.createTemp('dox_schedule');
      addTearDown(() => dir.delete(recursive: true));
      String path = '${dir.path}/out.log';
      Schedule s = Schedule();
      ScheduledTask task = s
          .exec('sh', args: <String>['-c', 'echo bad; exit 1'])
          .appendOutputTo(path);
      expect(await make(s).runTask(task, tick), TaskOutcome.failed);
      expect(await File(path).readAsString(), 'bad\n');
    });

    test('output hooks do nothing on a callback task', () async {
      Directory dir = await Directory.systemTemp.createTemp('dox_schedule');
      addTearDown(() => dir.delete(recursive: true));
      String path = '${dir.path}/out.log';
      bool called = false;
      Schedule s = Schedule();
      ScheduledTask task = s
          .call('a', () {})
          .sendOutputTo(path)
          .onOutput((String o) => called = true);
      expect(await make(s).runTask(task, tick), TaskOutcome.ran);
      expect(called, isFalse);
      expect(File(path).existsSync(), isFalse);
    });

    test('a custom name hides the args and allows the same line', () async {
      addTearDown(() => Schedule.doxExecutable = 'dox');
      Schedule.doxExecutable = 'echo';
      Schedule s = Schedule();
      s.command('sync', args: <String>['--token=secret']);
      expect(
        () => s.command('sync', args: <String>['--token=secret']),
        throwsArgumentError,
      );
      ScheduledTask task = s.command(
        'sync',
        args: <String>['--token=secret'],
        name: 'sync again',
      );
      expect(task.name, 'sync again');
      expect(s.exec('true', name: 'plain').name, 'plain');
      expect((await make(s).runDue(tick: tick))['sync again'], TaskOutcome.ran);
    });

    test('a throwing onOutput hook fails the task', () async {
      Schedule s = Schedule();
      ScheduledTask task = s
          .exec('echo', args: <String>['hi'])
          .onOutput((String output) => throw StateError('no'));
      expect(await make(s).runTask(task, tick), TaskOutcome.failed);
    });

    test('a file that can not be written fails the task, hooks still get '
        'the output', () async {
      List<String> seen = <String>[];
      Object? error;
      Schedule s = Schedule();
      ScheduledTask task = s
          .exec('echo', args: <String>['hi'])
          .sendOutputTo('/no/such/dir/out.log')
          .onOutput(seen.add)
          .onFailure((Object e, StackTrace st) => error = e);
      expect(await make(s).runTask(task, tick), TaskOutcome.failed);
      expect(seen, <String>['hi\n']);
      expect(error, isA<FileSystemException>());
    });

    test('timeout kills the process', () async {
      Schedule s = Schedule();
      ScheduledTask task = s
          .exec('sh', args: <String>['-c', 'exec sleep 30'])
          .withoutOverlapping()
          .timeout(const Duration(milliseconds: 100))
          .onEveryServer();
      Scheduler scheduler = make(s);
      Stopwatch watch = Stopwatch()..start();
      expect(await scheduler.runTask(task, tick), TaskOutcome.failed);
      // the process is gone, so its work ends and frees the overlap lock
      await scheduler.idle();
      while (await scheduler.runTask(task, tick) == TaskOutcome.skipped) {
        if (watch.elapsed > const Duration(seconds: 10)) {
          fail('the overlap lock was not freed in 10 s: not killed');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    test('stdin is closed, so cat ends at once', () async {
      Schedule s = Schedule();
      ScheduledTask task = s.exec('cat');
      expect(
        await make(s).runTask(task, tick).timeout(const Duration(seconds: 5)),
        TaskOutcome.ran,
      );
    });

    group('kill |', () {
      setUp(() => Schedule.processGrace = const Duration(milliseconds: 200));
      tearDown(() => Schedule.processGrace = const Duration(seconds: 5));

      /// [script] runs in sh with a 100 ms timeout. Gives when the
      /// process function really ended (its onOutput hook ran).
      Future<Duration> killed(String script) async {
        Completer<void> ended = Completer<void>();
        Schedule s = Schedule();
        ScheduledTask task = s
            .exec('sh', args: <String>['-c', script])
            .timeout(const Duration(milliseconds: 100))
            .onOutput((String o) => ended.complete());
        Stopwatch watch = Stopwatch()..start();
        expect(await make(s).runTask(task, tick), TaskOutcome.failed);
        await ended.future.timeout(const Duration(seconds: 5));
        return watch.elapsed;
      }

      test('a shell child that holds the pipes does not block', () async {
        Duration took = await killed('sleep 10 | cat');
        expect(took, lessThan(const Duration(seconds: 3)));
      });

      test('a process that ignores SIGTERM gets SIGKILL', () async {
        Duration took = await killed("trap '' TERM; sleep 10");
        expect(took, lessThan(const Duration(seconds: 3)));
      });
    });

    test('a non-zero exit code beats a hook and a file error', () async {
      Object? error;
      Schedule s = Schedule();
      ScheduledTask task = s
          .exec('sh', args: <String>['-c', 'echo hi; exit 4'])
          .sendOutputTo('/no/such/dir/out.log')
          .onOutput((String o) => throw StateError('hook'))
          .onFailure((Object e, StackTrace st) => error = e);
      expect(await make(s).runTask(task, tick), TaskOutcome.failed);
      expect(error, isA<ProcessException>());
      expect((error as ProcessException).errorCode, 4);
    });

    test('a large output (1 MB) does not block', () async {
      Directory dir = await Directory.systemTemp.createTemp('dox_schedule');
      addTearDown(() => dir.delete(recursive: true));
      String path = '${dir.path}/out.log';
      Schedule s = Schedule();
      ScheduledTask task = s
          .exec('head', args: <String>['-c', '1048576', '/dev/zero'])
          .sendOutputTo(path);
      expect(
        await make(s).runTask(task, tick).timeout(const Duration(seconds: 10)),
        TaskOutcome.ran,
      );
      expect(await File(path).length(), 1048576);
    });

    test('UTF-8 text split across chunks comes out right', () async {
      Directory dir = await Directory.systemTemp.createTemp('dox_schedule');
      addTearDown(() => dir.delete(recursive: true));
      String text = 'é' * 200000;
      File input = File('${dir.path}/in.txt')..writeAsStringSync(text);
      List<String> seen = <String>[];
      Schedule s = Schedule();
      ScheduledTask task = s
          .exec('cat', args: <String>[input.path])
          .onOutput(seen.add);
      expect(await make(s).runTask(task, tick), TaskOutcome.ran);
      expect(seen.single, text);
    });

    test('command runs the dox executable', () async {
      addTearDown(() => Schedule.doxExecutable = 'dox');
      Schedule.doxExecutable = 'echo';
      Schedule s = Schedule();
      ScheduledTask task = s.command(
        'queue:prune',
        args: <String>['--hours=48'],
      );
      expect(task.name, 'echo queue:prune --hours=48');
      expect((await make(s).runDue(tick: tick))[task.name], TaskOutcome.ran);
    });
  });

  group('ping |', () {
    // the real ping, kept before a test replaces it
    Future<void> Function(Uri url) defaultPing = ScheduledTask.sendPing;
    List<String> log = <String>[];
    setUp(() {
      log.clear();
      ScheduledTask.sendPing = (Uri url) async {
        log.add('ping ${url.path}');
        if (url.path == '/down') throw const SocketException('refused');
      };
    });
    tearDown(() {
      ScheduledTask.sendPing = defaultPing;
      ScheduledTask.pingTimeout = const Duration(seconds: 10);
    });

    test('order on success', () async {
      Schedule s = Schedule();
      s
          .call('a', () => log.add('run'))
          .pingBefore('http://x/before')
          .pingOnSuccess('http://x/success')
          .pingOnFailure('http://x/failure')
          .thenPing('http://x/after');
      await make(s).runDue(tick: tick);
      expect(log, <String>[
        'ping /before',
        'run',
        'ping /success',
        'ping /after',
      ]);
    });

    test('order on failure', () async {
      Schedule s = Schedule();
      s
          .call('a', () => throw StateError('boom'))
          .pingOnSuccess('http://x/success')
          .pingOnFailure('http://x/failure')
          .thenPing('http://x/after');
      await make(s).runDue(tick: tick);
      expect(log, <String>['ping /failure', 'ping /after']);
    });

    test('a failed ping is logged and does not fail the task', () async {
      StringBuffer out = StringBuffer();
      Schedule s = Schedule();
      s
          .call('a', () => log.add('run'))
          .pingBefore('http://x/down')
          .pingOnSuccess('http://x/down')
          .thenPing('http://x/down');
      Scheduler scheduler = Scheduler(
        tasks: s.tasks,
        store: CacheStore(MemoryDriver()),
        clock: FakeClock(tick),
        out: out,
        err: StringBuffer(),
      );
      expect((await scheduler.runDue(tick: tick))['a'], TaskOutcome.ran);
      expect(log, contains('run'));
      expect('ping http://x failed'.allMatches(out.toString()).length, 3);
      expect(out.toString(), isNot(contains('/down')));
    });

    test('the error text hides the secret path of the url', () {
      String url = 'https://hc.example.com:8443/ping/secret-token?x=1';
      String text = PingException(
        url,
        HttpException('status 500', uri: Uri.parse(url)),
      ).toString();
      expect(text, startsWith('ping https://hc.example.com:8443 failed'));
      expect(text, isNot(contains('secret-token')));
      expect(text, isNot(contains('x=1')));
    });

    test('the If forms', () async {
      Schedule s = Schedule();
      s
          .call('a', () {})
          .pingBeforeIf(false, 'http://x/no')
          .pingBeforeIf(true, 'http://x/before')
          .thenPingIf(false, 'http://x/no')
          .thenPingIf(true, 'http://x/after')
          .pingOnSuccessIf(false, 'http://x/no')
          .pingOnSuccessIf(true, 'http://x/success')
          .pingOnFailureIf(true, 'http://x/failure');
      await make(s).runDue(tick: tick);
      expect(log, <String>['ping /before', 'ping /success', 'ping /after']);
    });

    test('the default ping sends a GET', () async {
      HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      server.listen((HttpRequest request) {
        log.add('${request.method} ${request.uri.path}');
        request.response.statusCode = request.uri.path == '/bad' ? 500 : 200;
        request.response.close();
      });
      String base = 'http://127.0.0.1:${server.port}';
      await defaultPing(Uri.parse('$base/ok'));
      await expectLater(
        defaultPing(Uri.parse('$base/bad')),
        throwsA(isA<HttpException>()),
      );
      expect(log, <String>['GET /ok', 'GET /bad']);
    });

    test(
      'a ping that hangs fails at the limit and closes the socket',
      () async {
        ScheduledTask.pingTimeout = const Duration(milliseconds: 200);
        ServerSocket server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(server.close);
        Completer<void> closed = Completer<void>();
        // accept, read the request, never answer
        server.listen((Socket socket) {
          socket.listen((List<int> _) {}, onDone: closed.complete);
        });
        await expectLater(
          defaultPing(Uri.parse('http://127.0.0.1:${server.port}/hang')),
          throwsA(isA<TimeoutException>()),
        );
        await closed.future.timeout(const Duration(seconds: 2));
      },
    );

    test('a failed pingBefore is logged and the task runs', () async {
      StringBuffer out = StringBuffer();
      Schedule s = Schedule();
      s.call('a', () => log.add('run')).pingBefore('http://x/down');
      Scheduler scheduler = Scheduler(
        tasks: s.tasks,
        store: CacheStore(MemoryDriver()),
        clock: FakeClock(tick),
        out: out,
        err: StringBuffer(),
      );
      expect((await scheduler.runDue(tick: tick))['a'], TaskOutcome.ran);
      expect(log, <String>['ping /down', 'run']);
      expect(out.toString(), contains('a: ping http://x failed'));
    });

    test('a bad url throws when the schedule is made', () {
      ScheduledTask task = Schedule().call('a', () {});
      expect(() => task.pingBefore('not a url'), throwsArgumentError);
      expect(() => task.thenPing('ftp://x/y'), throwsArgumentError);
      expect(() => task.pingOnFailure('http://'), throwsArgumentError);
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
