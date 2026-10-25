import 'dart:io';

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

class FakeService implements DoxService, DoxShutdown {
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
class InProcess extends SchedulerService {
  InProcess() : super(schedule: schedule);

  @override
  Future<void> setup() async {
    FakeService.log.add('in-process');
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
    FakeService.log.clear();
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

  test('unknown command prints usage', () async {
    StringBuffer out = StringBuffer();
    expect(await runner(out).run(<String>['nope']), 64);
    expect(out.toString(), contains('Usage: dart run bin/schedule.dart'));
  });

  test('with app: starts and stops services, skips SchedulerService', () async {
    AppConfig app = AppConfig(
      appKey: 'a' * 32,
      services: <DoxService>[FakeService(), InProcess()],
      cache: const CacheConfig(
        defaultStore: 'memory',
        stores: <String, Map<String, dynamic>>{
          'memory': <String, dynamic>{'driver': 'memory'},
        },
      ),
    );
    StringBuffer out = StringBuffer();
    expect(await runner(out, app: app).run(<String>['run']), 0);
    expect(FakeService.log, <String>['setup', 'shutdown']);
    expect(ran, contains('cleanup'));
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
}
