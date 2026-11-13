import 'dart:async';

import 'package:dox_cache/dox_cache.dart';
import 'package:dox_scheduler/dox_scheduler.dart';
import 'package:test/test.dart';

import 'fake_clock.dart';

final DateTime _tick = DateTime.utc(2026, 10, 25, 2);

/// The `clear-cache` cases for one lock store. [open] gives a store on
/// the same data each time, like a new process (call it in a test).
void clearCacheCases(CacheStore Function() open) {
  Scheduler make(Schedule s, CacheStore store) {
    return Scheduler(
      tasks: s.tasks,
      store: store,
      clock: FakeClock(_tick),
      err: StringBuffer(),
    );
  }

  test('a lock left by a crash skips the task, until clear', () async {
    Completer<void> gate = Completer<void>();
    addTearDown(gate.complete);
    int runs = 0;
    Schedule s = Schedule();
    ScheduledTask task = s
        .call('a', () {
          runs++;
          // the first run hangs, like a process that crashed
          return runs == 1 ? gate.future : null;
        })
        .withoutOverlapping()
        .onEveryServer();
    s.call('b', () {}).withoutOverlapping().onEveryServer();
    // the crashed process: it took the lock and never freed it
    unawaited(make(s, open()).runTask(task, _tick));
    await waitUntil(() => runs == 1);

    CacheStore store = open();
    CacheLock appLock = store.lock('report', const Duration(minutes: 5));
    expect(await appLock.get(), isTrue);
    await store.put('keep', 'me');

    Scheduler next = make(s, store);
    DateTime later = _tick.add(const Duration(minutes: 1));
    expect(await next.runTask(task, later), TaskOutcome.skipped);
    // only the lock that was there
    expect(await next.clearOverlapLocks(), <String>['a']);
    expect(await next.runTask(task, later), TaskOutcome.ran);
    expect(runs, 2);

    // other keys stay
    expect(await store.get('keep'), 'me');
    expect(await store.lock('report').get(), isFalse);
    await appLock.release();
  });

  test('nothing to clear', () async {
    Schedule s = Schedule();
    s.call('a', () {}).withoutOverlapping();
    s.call('b', () {});
    expect(await make(s, open()).clearOverlapLocks(), isEmpty);
  });
}
