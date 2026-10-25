import 'package:dox_scheduler/dox_scheduler.dart';
import 'package:test/test.dart';

void noop() {}

ScheduledTask task() {
  return ScheduledTask('t', noop);
}

String cron(ScheduledTask task) {
  return task.expression.expression;
}

void main() {
  group('frequencies |', () {
    test('default is every minute', () {
      expect(cron(task()), '* * * * *');
    });

    test('minutes', () {
      expect(cron(task().everyMinute()), '* * * * *');
      expect(cron(task().everyTwoMinutes()), '*/2 * * * *');
      expect(cron(task().everyFiveMinutes()), '*/5 * * * *');
      expect(cron(task().everyTenMinutes()), '*/10 * * * *');
      expect(cron(task().everyFifteenMinutes()), '*/15 * * * *');
      expect(cron(task().everyThirtyMinutes()), '0,30 * * * *');
    });

    test('hours and days', () {
      expect(cron(task().hourly()), '0 * * * *');
      expect(cron(task().hourlyAt(17)), '17 * * * *');
      expect(cron(task().daily()), '0 0 * * *');
      expect(cron(task().dailyAt('02:30')), '30 2 * * *');
      expect(cron(task().dailyAt('2:05')), '5 2 * * *');
      expect(cron(task().twiceDaily()), '0 1,13 * * *');
      expect(cron(task().twiceDaily(8, 20)), '0 8,20 * * *');
    });

    test('weeks, months, years', () {
      expect(cron(task().weekly()), '0 0 * * 0');
      expect(cron(task().weeklyOn(DateTime.monday, '08:00')), '0 8 * * 1');
      expect(cron(task().weeklyOn(DateTime.sunday)), '0 0 * * 0');
      expect(cron(task().monthly()), '0 0 1 * *');
      expect(cron(task().monthlyOn(15, '12:00')), '0 12 15 * *');
      expect(cron(task().yearly()), '0 0 1 1 *');
    });

    test('day filters keep the time, in any order', () {
      expect(cron(task().weekdays().dailyAt('09:00')), '0 9 * * 1-5');
      expect(cron(task().dailyAt('09:00').weekends()), '0 9 * * 0,6');
      expect(
        cron(task().hourly().days(<int>[DateTime.monday, DateTime.sunday])),
        '0 * * * 1,0',
      );
    });

    test('cron() then a day filter', () {
      expect(cron(task().cron('*/5 * * * *').weekdays()), '*/5 * * * 1-5');
    });

    test('bad values throw', () {
      expect(() => task().dailyAt('25:00'), throwsRangeError);
      expect(() => task().dailyAt('2pm'), throwsFormatException);
      expect(() => task().hourlyAt(60), throwsRangeError);
      expect(() => task().monthlyOn(0), throwsRangeError);
      expect(() => task().weeklyOn(8), throwsRangeError);
      expect(() => task().cron('* * *'), throwsFormatException);
      expect(() => task().timezone('Mars/Base'), throwsArgumentError);
    });
  });

  group('isDue and filters |', () {
    test('isDue', () {
      ScheduledTask t = task().dailyAt('02:00');
      expect(t.isDue(DateTime.utc(2026, 1, 1, 2)), isTrue);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 2, 1)), isFalse);
    });

    test('between', () {
      ScheduledTask t = task().hourly().between('09:00', '17:00');
      expect(t.isDue(DateTime.utc(2026, 1, 1, 8)), isFalse);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 9)), isTrue);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 17)), isTrue);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 18)), isFalse);
    });

    test('between across midnight', () {
      ScheduledTask t = task().hourly().between('22:00', '02:00');
      expect(t.isDue(DateTime.utc(2026, 1, 1, 23)), isTrue);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 1)), isTrue);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 12)), isFalse);
    });

    test('when and skip', () async {
      bool open = true;
      bool holiday = false;
      ScheduledTask t = task();
      t.when(() => open).skip(() async => holiday);
      expect(await t.filtersPass(), isTrue);
      holiday = true;
      expect(await t.filtersPass(), isFalse);
      holiday = false;
      open = false;
      expect(await t.filtersPass(), isFalse);
    });

    test('describe', () {
      expect(task().dailyAt('02:00').describe(), '0 2 * * *');
      expect(
        task().dailyAt('02:00').timezone('Asia/Yangon').describe(),
        '0 2 * * * Asia/Yangon',
      );
    });
  });

  group('nextRun |', () {
    test('UTC', () {
      ScheduledTask t = task().dailyAt('02:00');
      expect(
        t.nextRun(DateTime.utc(2026, 1, 1, 1, 59, 30)),
        DateTime.utc(2026, 1, 1, 2),
      );
      // strictly after now
      expect(
        t.nextRun(DateTime.utc(2026, 1, 1, 2)),
        DateTime.utc(2026, 1, 2, 2),
      );
    });

    test('with between', () {
      ScheduledTask t = task().hourly().between('09:00', '10:00');
      expect(
        t.nextRun(DateTime.utc(2026, 1, 1, 11)),
        DateTime.utc(2026, 1, 2, 9),
      );
    });

    test('never', () {
      expect(task().cron('0 0 30 2 *').nextRun(DateTime.utc(2026)), isNull);
      expect(
        task()
            .dailyAt('08:00')
            .between('09:00', '10:00')
            .nextRun(DateTime.utc(2026)),
        isNull,
      );
    });

    test('fixed offset zone: Asia/Yangon is UTC+06:30', () {
      ScheduledTask t = task().dailyAt('02:00').timezone('Asia/Yangon');
      expect(t.nextRun(DateTime.utc(2026)), DateTime.utc(2026, 1, 1, 19, 30));
      expect(t.isDue(DateTime.utc(2026, 1, 1, 19, 30)), isTrue);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 2)), isFalse);
    });
  });

  group('summer time (America/New_York) |', () {
    // 2026-03-08: 02:00 -> 03:00. 2026-11-01: 02:00 -> 01:00.
    test('a skipped wall time does not run that day', () {
      ScheduledTask t = task().dailyAt('02:30').timezone('America/New_York');
      // Mar 7 02:30 EST = 07:30 UTC, Mar 8 02:30 does not exist,
      // Mar 9 02:30 EDT = 06:30 UTC
      expect(
        t.nextRun(DateTime.utc(2026, 3, 7, 8)),
        DateTime.utc(2026, 3, 9, 6, 30),
      );
    });

    test('a repeated wall time runs once', () {
      ScheduledTask t = task().dailyAt('01:30').timezone('America/New_York');
      // 01:30 EDT = 05:30 UTC, then 01:30 EST = 06:30 UTC
      expect(t.isDue(DateTime.utc(2026, 11, 1, 5, 30)), isTrue);
      expect(t.isDue(DateTime.utc(2026, 11, 1, 6, 30)), isFalse);
      expect(
        t.nextRun(DateTime.utc(2026, 11, 1, 5, 30)),
        DateTime.utc(2026, 11, 2, 6, 30),
      );
    });

    test('hourly keeps running every real hour', () {
      ScheduledTask t = task().hourly().timezone('America/New_York');
      int runs = 0;
      DateTime m = DateTime.utc(2026, 11);
      for (int i = 0; i < 24 * 60; i++) {
        if (t.isDue(m)) runs++;
        m = m.add(const Duration(minutes: 1));
      }
      // 24 UTC hours: the repeated 01:00 runs once, so 23
      expect(runs, 23);
    });
  });
}
