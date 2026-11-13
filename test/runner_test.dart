import 'dart:io';

import 'package:dox_cache/dox_cache.dart' show MemoryDriver;
import 'package:dox_core/dox_core.dart';
import 'package:dox_scheduler/dox_scheduler.dart';
import 'package:test/test.dart';

import 'fake_clock.dart';

final DateTime tick = DateTime.utc(2026, 10, 25, 2);

List<String> ran = <String>[];

void schedule(Schedule s) {
  s.call('cleanup', () => ran.add('cleanup')).dailyAt('02:00');
  s.call('report', () => ran.add('report')).hourly();
  s
      .call('ping', () => ran.add('ping'))
      .cron('*/5 * * * *')
      .timezone('Asia/Yangon');
  s.call('broken', () => throw StateError('boom')).dailyAt('03:00');
}

class FakeProvider extends DoxProvider {
  static List<String> log = <String>[];

  @override
  void setup() {
    log.add('setup');
  }

  @override
  void shutdown() {
    log.add('shutdown');
  }
}

/// must be skipped by the runner
class InProcess extends SchedulerProvider {
  InProcess() : super(schedule: schedule);

  @override
  Future<void> setup() async {
    FakeProvider.log.add('in-process');
  }
}

class OtherProvider extends DoxProvider {
  @override
  void setup() {
    FakeProvider.log.add('other setup');
  }

  @override
  void shutdown() {
    FakeProvider.log.add('other shutdown');
  }
}

/// logs its setup() and boot()
class BootProvider extends DoxProvider {
  BootProvider(this.name);

  final String name;

  @override
  void setup() => FakeProvider.log.add('$name setup');

  @override
  Future<void> boot() async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    FakeProvider.log.add('$name boot');
  }
}

/// a second type: the runner starts one provider per type
class BootProvider2 extends BootProvider {
  BootProvider2() : super('b');
}

class BrokenProvider extends DoxProvider {
  @override
  void setup() {
    throw StateError('setup failed');
  }

  @override
  void shutdown() {
    FakeProvider.log.add('broken shutdown');
  }
}

SchedulerRunner runner(StringBuffer out, {DateTime? now, AppConfig? app}) {
  return SchedulerRunner(
    schedule: schedule,
    app: app,
    clock: FakeClock(now ?? tick),
    out: out,
  );
}

void main() {
  setUp(() {
    ran.clear();
    FakeProvider.log.clear();
  });

  test('list', () async {
    StringBuffer out = StringBuffer();
    int code = await runner(
      out,
      now: DateTime.utc(2026, 10, 25, 1, 30),
    ).run(<String>['list']);
    expect(code, 0);
    List<String> lines = out.toString().trim().split('\n');
    expect(lines[0], startsWith('Task'));
    expect(lines[1], contains('cleanup'));
    expect(lines[1], contains('0 2 * * *'));
    expect(lines[1], endsWith('2026-10-25 02:00 UTC'));
    expect(lines[2], endsWith('2026-10-25 02:00 UTC'));
    // 01:30 UTC is 08:00 in Yangon
    expect(lines[3], contains('*/5 * * * * Asia/Yangon'));
    expect(lines[3], endsWith('2026-10-25 08:05 Asia/Yangon'));
    expect(ran, isEmpty);
  });

  test('list shows between, unlessBetween and environments', () async {
    void filtered(Schedule s) {
      s
          .call('office', () {})
          .hourly()
          .between('9', '17:30')
          .unlessBetween('12:00', '13:00')
          .environments(<String>['Production', 'staging']);
      s.call('plain', () {}).hourly();
    }

    StringBuffer out = StringBuffer();
    int code = await SchedulerRunner(
      schedule: filtered,
      clock: FakeClock(DateTime.utc(2026, 10, 25, 1, 30)),
      out: out,
    ).run(<String>['list']);
    expect(code, 0);
    List<String> lines = out.toString().trim().split('\n');
    expect(
      lines[1],
      contains(
        '0 * * * *, between 09:00-17:30, unless between 12:00-13:00, '
        'env production|staging',
      ),
    );
    // the next run checks between(): not 02:00, but 09:00
    expect(lines[1], endsWith('2026-10-25 09:00 UTC'));
    expect(lines[2], isNot(contains('between')));
    expect(lines[2], endsWith('2026-10-25 02:00 UTC'));
  });

  test('list with ScheduleConfig timezone', () async {
    StringBuffer out = StringBuffer();
    int code = await SchedulerRunner(
      schedule: schedule,
      config: const ScheduleConfig(timezone: 'Asia/Yangon'),
      clock: FakeClock(DateTime.utc(2026, 10, 25, 1, 30)),
      out: out,
    ).run(<String>['list']);
    expect(code, 0);
    List<String> lines = out.toString().trim().split('\n');
    // cleanup gets the config zone: 02:00 in Yangon
    expect(lines[1], contains('0 2 * * * Asia/Yangon'));
    expect(lines[1], endsWith('2026-10-26 02:00 Asia/Yangon'));
  });

  test('an unknown ScheduleConfig timezone throws', () async {
    SchedulerRunner r = SchedulerRunner(
      schedule: schedule,
      config: const ScheduleConfig(timezone: 'Mars/Base'),
      out: StringBuffer(),
    );
    expect(() => r.run(<String>['list']), throwsArgumentError);
  });

  test('run: due tasks once, exit 0', () async {
    StringBuffer out = StringBuffer();
    expect(await runner(out).run(<String>['run']), 0);
    // 02:00 UTC is 08:30 in Yangon, a multiple of 5
    expect(ran, <String>['cleanup', 'report', 'ping']);
    expect(out.toString(), contains('done cleanup'));
  });

  test('run: a failed task gives exit 1', () async {
    StringBuffer out = StringBuffer();
    int code = await runner(
      out,
      now: DateTime.utc(2026, 10, 25, 3),
    ).run(<String>['run']);
    expect(code, 1);
    expect(out.toString(), contains('fail broken'));
  });

  test('run: a sub-minute task repeats until the minute ends', () async {
    int runs = 0;
    FakeClock clock = FakeClock(tick);
    int code = await SchedulerRunner(
      schedule: (Schedule s) {
        s.call('fast', () => runs++).everyFifteenSeconds();
      },
      clock: clock,
      out: StringBuffer(),
    ).run(<String>['run']);
    expect(code, 0);
    expect(runs, 4);
    expect(clock.now(), tick.add(const Duration(seconds: 45)));
  });

  test('test <name> runs one task now', () async {
    StringBuffer out = StringBuffer();
    int code = await runner(
      out,
      now: DateTime.utc(2026, 10, 25, 7, 7),
    ).run(<String>['test', 'cleanup']);
    expect(code, 0);
    expect(ran, <String>['cleanup']);
    expect(await runner(out).run(<String>['test', 'broken']), 1);
  });

  test('test with an unknown or missing name', () async {
    StringBuffer out = StringBuffer();
    expect(await runner(out).run(<String>['test', 'nope']), 1);
    expect(out.toString(), contains('No task named "nope"'));
    expect(await runner(out).run(<String>['test']), 64);
  });

  test('clear-cache removes the overlap lock of each task', () async {
    CacheStore store = CacheStore(MemoryDriver());
    // a crash left these
    Duration hour = const Duration(hours: 1);
    await store.lock('dox_schedule:overlap:cleanup', hour).get();
    await store.lock('dox_schedule:overlap:ping', hour).get();
    await store.put('keep', 1);
    StringBuffer out = StringBuffer();
    SchedulerRunner r = SchedulerRunner(
      schedule: schedule,
      clock: FakeClock(tick),
      store: store,
      out: out,
    );
    expect(await r.run(<String>['clear-cache']), 0);
    expect(
      out.toString(),
      'Removed the overlap lock of cleanup.\n'
      'Removed the overlap lock of ping.\n',
    );
    expect(await store.get('keep'), 1);
    expect(ran, isEmpty);

    out.clear();
    expect(await r.run(<String>['clear-cache']), 0);
    expect(out.toString(), 'No overlap locks found. Nothing to clear.\n');
  });

  test('unknown command prints usage', () async {
    StringBuffer out = StringBuffer();
    expect(await runner(out).run(<String>['nope']), 64);
    expect(out.toString(), contains('Usage: dart run bin/schedule.dart'));
  });

  test(
    'with app: starts and stops providers, skips SchedulerProvider',
    () async {
      AppConfig app = AppConfig(
        appKey: 'a' * 32,
        providers: <DoxProvider>[FakeProvider(), InProcess()],
        cache: const CacheConfig(
          defaultStore: 'memory',
          stores: <String, Map<String, dynamic>>{
            'memory': <String, dynamic>{'driver': 'memory'},
          },
        ),
      );
      StringBuffer out = StringBuffer();
      expect(await runner(out, app: app).run(<String>['run']), 0);
      expect(FakeProvider.log, <String>['setup', 'shutdown']);
      expect(ran, contains('cleanup'));
    },
  );

  test('with app: boot() runs after setup() of every provider', () async {
    AppConfig app = AppConfig(
      appKey: 'a' * 32,
      providers: <DoxProvider>[BootProvider('a'), BootProvider2()],
      cache: const CacheConfig(
        defaultStore: 'memory',
        stores: <String, Map<String, dynamic>>{
          'memory': <String, dynamic>{'driver': 'memory'},
        },
      ),
    );
    StringBuffer out = StringBuffer();
    expect(await runner(out, app: app).run(<String>['run']), 0);
    expect(FakeProvider.log, <String>[
      'a setup',
      'b setup',
      'a boot',
      'b boot',
    ]);
  });

  test('with app: a setup error shuts down the started providers', () async {
    AppConfig app = AppConfig(
      appKey: 'a' * 32,
      providers: <DoxProvider>[
        FakeProvider(),
        OtherProvider(),
        BrokenProvider(),
      ],
      cache: const CacheConfig(
        defaultStore: 'memory',
        stores: <String, Map<String, dynamic>>{
          'memory': <String, dynamic>{'driver': 'memory'},
        },
      ),
    );
    StringBuffer out = StringBuffer();
    await expectLater(
      runner(out, app: app).run(<String>['run']),
      throwsA(isA<StateError>()),
    );
    expect(FakeProvider.log, <String>[
      'setup',
      'other setup',
      'other shutdown',
      'shutdown',
    ]);
    expect(ran, isEmpty);
  });

  test(
    'work: SIGINT stops it after the running task ends',
    () async {
      Process process = await Process.start(
        Platform.resolvedExecutable,
        <String>['run', 'test/fixtures/work.dart', 'work'],
      );
      List<String> lines = <String>[];
      bool signalled = false;
      Future<void> reading = process.stdout
          .transform(const SystemEncoding().decoder)
          .forEach((String chunk) {
            lines.addAll(chunk.split('\n'));
            if (!signalled && chunk.contains('started')) {
              signalled = true;
              process.kill(ProcessSignal.sigint);
            }
          });
      int code = await process.exitCode.timeout(const Duration(seconds: 60));
      await reading;
      String text = lines.join('\n');
      expect(code, 0);
      expect(text, contains('stopping'));
      expect(
        text.lastIndexOf('finished'),
        greaterThan(text.indexOf('stopping')),
      );
    },
    skip: Platform.isWindows ? 'no signals on Windows' : null,
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'work: SIGINT during a long real sleep ends the process in a few seconds',
    () async {
      Process process = await Process.start(
        Platform.resolvedExecutable,
        <String>['run', 'test/fixtures/work_real_clock.dart', 'work'],
      );
      bool signalled = false;
      Future<void> reading = process.stdout
          .transform(const SystemEncoding().decoder)
          .forEach((String chunk) {
            if (!signalled && chunk.contains('working')) {
              signalled = true;
              process.kill(ProcessSignal.sigint);
            }
          });
      // before the fix it always waited the full 59 s sleep
      int code = await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      await reading;
      expect(signalled, true);
      expect(code, 0);
    },
    skip: Platform.isWindows ? 'no signals on Windows' : null,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
