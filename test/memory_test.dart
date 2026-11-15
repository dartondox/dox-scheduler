import 'dart:io';

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

    test('default out of Scheduler is bounded', () {
      Scheduler scheduler = Scheduler(
        tasks: <ScheduledTask>[],
        store: CacheStore(MemoryDriver()),
      );
      expect(scheduler.out, isA<BoundedSink>());
    });
  });

  group('default ping |', () {
    test('reuses one connection, and close frees it', () async {
      HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      server.listen((HttpRequest request) async {
        request.response.statusCode = 200;
        await request.response.close();
      });
      Uri url = Uri.parse('http://127.0.0.1:${server.port}/ok');
      Future<void> Function(Uri) ping = ScheduledTask.sendPing;
      try {
        await ping(url);
        await ping(url);
        await ping(url);
        expect(server.connectionsInfo().total, 1);
      } finally {
        ScheduledTask.closePingClient();
        await server.close(force: true);
      }
    });
  });
}
