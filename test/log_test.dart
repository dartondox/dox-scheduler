import 'dart:async';
import 'dart:io';

import 'package:dox_cache/dox_cache.dart';
import 'package:dox_core/dox_core.dart';
import 'package:dox_core/utils/log_buffer.dart';
import 'package:dox_scheduler/dox_scheduler.dart';
import 'package:dox_scheduler/src/scheduler_log.dart';
import 'package:test/test.dart';

import 'fake_clock.dart';

/// 02:00 UTC
final DateTime tick = DateTime.utc(2026, 10, 25, 2);

/// what the Logger wrote, one entry per line
List<String> logged = <String>[];

void logger({bool enabled = true, String level = 'info'}) {
  Dox().config = AppConfig(
    appKey: 'x',
    logger: LoggerConfig(enabled: enabled, prettyPrint: true, level: level),
  );
}

/// The pretty line of the Logger, with the `[scheduler]` tag.
String pretty(String color, String message) {
  return '\x1B[2m[scheduler]\x1B[0m \x1B[${color}m$message\x1B[0m';
}

List<String> flushed() {
  LogBuffer.flush();
  return logged
      .expand((String w) => w.split('\n'))
      .where((String l) => l.isNotEmpty)
      .toList();
}

void main() {
  late StringBuffer out;
  late StringBuffer err;
  late Scheduler scheduler;
  late ScheduledTask slow;
  late Completer<void> gate;

  setUp(() {
    logged = <String>[];
    LogBuffer.writer = logged.add;
    out = StringBuffer();
    err = StringBuffer();
    gate = Completer<void>();
    Schedule s = Schedule();
    s.call('ok', () {});
    s.call('bad', () => throw StateError('boom'));
    slow = s
        .call('slow', () => gate.future)
        .withoutOverlapping()
        .onEveryServer();
    scheduler = Scheduler(
      tasks: s.tasks,
      store: CacheStore(MemoryDriver()),
      clock: FakeClock(tick),
      out: out,
      err: err,
      flags: const SchedulerFlags(loggerLines: true),
    );
  });

  tearDown(LogBuffer.flush);

  test('task lines go to the Logger with the scheduler tag', () async {
    logger();
    await scheduler.runTask(scheduler.tasks[0], tick);
    await scheduler.runTask(scheduler.tasks[1], tick);
    Future<TaskOutcome> first = scheduler.runTask(slow, tick);
    await scheduler.runTask(slow, tick.add(const Duration(minutes: 1)));
    gate.complete();
    await first;
    List<String> lines = flushed();
    expect(lines[0], pretty('36', 'running ok'));
    expect(lines[1], matches(RegExp(r'\[32mran ok in \d+ms')));
    expect(lines[2], pretty('36', 'running bad'));
    expect(
      lines[3],
      matches(RegExp(r'\[31mfailed bad in \d+ms: Bad state: boom')),
    );
    expect(lines[4], pretty('36', 'running slow'));
    expect(lines[5], pretty('36', 'skipped slow: the last run still runs'));
    expect(lines[6], matches(RegExp(r'\[32mran slow in \d+ms')));
    expect(lines.length, 7);
    for (String line in lines) {
      expect(line, startsWith('\x1B[2m[scheduler]\x1B[0m '));
    }
  });

  test('out still gets the same plain lines', () async {
    logger();
    await scheduler.runTask(scheduler.tasks[0], tick);
    String stamp = tick.toIso8601String();
    List<String> lines = out.toString().trim().split('\n');
    expect(lines[0], '[schedule] $stamp run ok');
    expect(lines[1], matches(RegExp('^\\[schedule\\] $stamp done ok \\(')));
  });

  test('the logger off: no Logger lines, out is the same', () async {
    logger(enabled: false);
    await scheduler.runTask(scheduler.tasks[0], tick);
    expect(flushed(), isEmpty);
    expect(out.toString(), contains('run ok'));
  });

  test('the level hides lower lines', () async {
    logger(level: 'error');
    await scheduler.runTask(scheduler.tasks[0], tick);
    await scheduler.runTask(scheduler.tasks[1], tick);
    List<String> lines = flushed();
    expect(lines.single, contains('failed bad'));
  });

  test('the lock store warning goes to err and the Logger', () async {
    logger();
    Directory dir = await Directory.systemTemp.createTemp('dox_schedule');
    addTearDown(() => dir.delete(recursive: true));
    Schedule s = Schedule();
    s.call('a', () {});
    Scheduler withFile = Scheduler(
      tasks: s.tasks,
      store: CacheStore(FileDriver(directory: dir)),
      clock: FakeClock(tick),
      out: out,
      err: err,
      flags: const SchedulerFlags.all(),
    );
    withFile.warnIfLockNotShared();
    expect(err.toString(), startsWith('[schedule] warning: the lock store'));
    String warn = flushed().single;
    expect(warn, startsWith('\x1B[2m[scheduler]\x1B[0m \x1B[33mthe lock'));
  });

  test('the flag off: no Logger lines, out is the same', () async {
    logger();
    Schedule s = Schedule();
    s.call('ok', () {});
    Scheduler off = Scheduler(
      tasks: s.tasks,
      store: CacheStore(MemoryDriver()),
      clock: FakeClock(tick),
      out: out,
      err: err,
    );
    await off.runTask(s.tasks.single, tick);
    expect(flushed(), isEmpty);
    expect(out.toString(), startsWith('[schedule] ${tick.toIso8601String()}'));
  });

  test('a Logger that throws keeps the plain line', () async {
    logger();
    void Function(String, String) saved = SchedulerLog.logger;
    SchedulerLog.logger = (String level, String message) {
      throw StateError('no log');
    };
    addTearDown(() => SchedulerLog.logger = saved);
    SchedulerLog.write(
      stdout,
      const SchedulerFlags.all(),
      SchedulerLogLevel.info,
      '[schedule] plain',
      'message',
    );
    SchedulerLog.write(
      out,
      const SchedulerFlags.all(),
      SchedulerLogLevel.info,
      '[schedule] plain',
      'message',
    );
    expect(out.toString(), '[schedule] plain\n');
  });

  group('process |', () {
    const String stamp = '2026-10-25T00:00:00.000Z';
    const String warning =
        '[schedule] warning: the lock store is a memory store. It is not '
        'shared between servers, so onOneServer() works only inside one '
        'server. When many servers run the schedule, each server runs the '
        "task. Use a Redis cache store: ScheduleConfig(store: 'redis').\n";
    RegExp oldOut = RegExp(
      '^\\[schedule\\] $stamp run a\\n'
      '\\[schedule\\] $stamp done a \\(\\d+ ms\\)\\n\$',
    );

    Future<ProcessResult> run(String mode) {
      return Process.run(
        Platform.resolvedExecutable,
        <String>['run', 'test/fixtures/run_logged.dart', mode],
        environment: <String, String>{'APP_ENV': 'production'},
      );
    }

    test('flag off: the old output, exactly', () async {
      ProcessResult result = await run('off');
      expect(result.exitCode, 0);
      expect(result.stdout as String, matches(oldOut));
      expect(result.stderr, warning);
    });

    test('flag on with no Dox().config: the old output', () async {
      ProcessResult result = await run('no-config');
      expect(result.exitCode, 0);
      expect(result.stdout as String, matches(oldOut));
      expect(result.stderr, warning);
    });

    test('flag on: each line once, from the Logger', () async {
      ProcessResult result = await run('on');
      String text = result.stdout as String;
      expect(result.exitCode, 0);
      expect('running a'.allMatches(text).length, 1);
      expect(text, contains(pretty('36', 'running a')));
      expect(text, matches(RegExp(r'\[32mran a in \d+ms')));
      expect(text, contains('\x1B[33mthe lock store is a memory store'));
      expect(text, isNot(contains('[schedule]')));
      expect(result.stderr, '');
    });

    test('flag on, level warn: plain start and done lines stay', () async {
      ProcessResult result = await run('warn');
      String text = result.stdout as String;
      expect(result.exitCode, 0);
      expect(text, contains('[schedule] $stamp run a\n'));
      expect(
        text,
        matches(RegExp('\\[schedule\\] $stamp done a \\(\\d+ ms\\)')),
      );
      expect(text, isNot(contains('running a')));
      expect(text, contains('\x1B[33mthe lock store is a memory store'));
      expect(result.stderr, '');
    });
  });
}
