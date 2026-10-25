import 'package:dox_cache/dox_cache.dart';
import 'package:dox_core/dox_core.dart';
import 'package:dox_scheduler/dox_scheduler.dart';
import 'package:test/test.dart';

import 'fake_clock.dart';

int runs = 0;

void schedule(Schedule s) {
  s.call('count', () => runs++);
}

SchedulerService service(bool inProcess, CacheStore store) {
  return SchedulerService(
    schedule: schedule,
    config: ScheduleConfig(inProcess: inProcess),
    clock: FakeClock(DateTime.utc(2026, 10, 25)),
    store: store,
    out: StringBuffer(),
  );
}

void main() {
  setUp(() {
    runs = 0;
    Dox().isolateId = 1;
  });

  test('off by default', () async {
    SchedulerService s = service(false, CacheStore(MemoryDriver()));
    await s.setup();
    expect(s.scheduler, isNull);
    await s.shutdown();
  });

  test('runs in isolate 1 and stops on shutdown', () async {
    SchedulerService s = service(true, CacheStore(MemoryDriver()));
    await s.setup();
    expect(s.scheduler, isNotNull);
    while (runs < 3) {
      await Future<void>.delayed(Duration.zero);
    }
    await s.shutdown();
    int after = runs;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(runs, after);
    expect(s.scheduler, isNull);
  });

  test('other isolates do not run it', () async {
    Dox().isolateId = 2;
    SchedulerService s = service(true, CacheStore(MemoryDriver()));
    await s.setup();
    expect(s.scheduler, isNull);
  });
}
