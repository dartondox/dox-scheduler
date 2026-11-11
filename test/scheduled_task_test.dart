import 'package:dox_core/dox_core.dart';
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

    test('seconds', () {
      expect(task().repeatSeconds, isNull);
      Map<int, ScheduledTask> tasks = <int, ScheduledTask>{
        1: task().hourly().everySecond(),
        2: task().everyTwoSeconds(),
        5: task().everyFiveSeconds(),
        10: task().everyTenSeconds(),
        15: task().everyFifteenSeconds(),
        20: task().everyTwentySeconds(),
        30: task().everyThirtySeconds(),
      };
      tasks.forEach((int seconds, ScheduledTask t) {
        expect(t.repeatSeconds, seconds);
        expect(cron(t), '* * * * *');
      });
      expect(task().everyFiveSeconds().describeFilters(), 'every 5s');
      // a frequency after it limits the due minutes
      expect(cron(task().everyFiveSeconds().hourly()), '0 * * * *');
    });

    test('hours and days', () {
      expect(cron(task().hourly()), '0 * * * *');
      expect(cron(task().hourlyAt(17)), '17 * * * *');
      expect(cron(task().daily()), '0 0 * * *');
      expect(cron(task().dailyAt('02:30')), '30 2 * * *');
      expect(cron(task().dailyAt('2:05')), '5 2 * * *');
      expect(cron(task().dailyAt('13')), '0 13 * * *');
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
      expect(() => task().dailyAt(''), throwsFormatException);
      expect(() => task().dailyAt('24'), throwsRangeError);
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

  group('more frequencies |', () {
    test('minutes and hours', () {
      expect(cron(task().everyThreeMinutes()), '*/3 * * * *');
      expect(cron(task().everyFourMinutes()), '*/4 * * * *');
      expect(cron(task().everyTwoHours()), '0 */2 * * *');
      expect(cron(task().everyThreeHours(15)), '15 */3 * * *');
      expect(cron(task().everyFourHours()), '0 */4 * * *');
      expect(cron(task().everySixHours(30)), '30 */6 * * *');
      expect(cron(task().everyOddHour()), '0 1-23/2 * * *');
      expect(cron(task().everyOddHour(5)), '5 1-23/2 * * *');
    });

    test('days', () {
      expect(cron(task().twiceDailyAt()), '0 1,13 * * *');
      expect(cron(task().twiceDailyAt(3, 15, 30)), '30 3,15 * * *');
      expect(cron(task().at('07:45')), '45 7 * * *');
      expect(cron(task().mondays()), '* * * * 1');
      expect(cron(task().tuesdays()), '* * * * 2');
      expect(cron(task().wednesdays()), '* * * * 3');
      expect(cron(task().thursdays()), '* * * * 4');
      expect(cron(task().fridays()), '* * * * 5');
      expect(cron(task().saturdays()), '* * * * 6');
      expect(cron(task().sundays().at('09:00')), '0 9 * * 0');
    });

    test('months and years', () {
      expect(cron(task().lastDayOfMonth()), '0 0 28-31 * *');
      expect(cron(task().lastDayOfMonth('23:30')), '30 23 28-31 * *');
      expect(cron(task().twiceMonthly()), '0 0 1,16 * *');
      expect(cron(task().twiceMonthly(5, 20, '08:00')), '0 8 5,20 * *');
      expect(cron(task().quarterly()), '0 0 1 1,4,7,10 *');
      expect(cron(task().quarterlyOn(15, '06:00')), '0 6 15 1,4,7,10 *');
      expect(cron(task().yearlyOn()), '0 0 1 1 *');
      expect(cron(task().yearlyOn(6, 30, '12:00')), '0 12 30 6 *');
    });

    test('bad values throw', () {
      expect(() => task().everyTwoHours(60), throwsRangeError);
      expect(() => task().everyOddHour(-1), throwsRangeError);
      expect(() => task().twiceDailyAt(1, 24), throwsRangeError);
      expect(() => task().twiceDailyAt(1, 13, 60), throwsRangeError);
      expect(() => task().twiceMonthly(0), throwsRangeError);
      expect(() => task().twiceMonthly(1, 32), throwsRangeError);
      expect(() => task().quarterlyOn(32), throwsRangeError);
      expect(() => task().yearlyOn(13), throwsRangeError);
      expect(() => task().lastDayOfMonth('24:00'), throwsRangeError);
      expect(() => task().unlessBetween('9', '25'), throwsRangeError);
      expect(() => task().environments(<String>[]), throwsArgumentError);
      expect(
        () => task().environments(<String>['production', ' ']),
        throwsArgumentError,
      );
    });

    test('a bad value does not change the task', () {
      ScheduledTask t = task();
      expect(() => t.quarterlyOn(32), throwsRangeError);
      expect(() => t.quarterlyOn(1, '25:00'), throwsRangeError);
      expect(() => t.yearlyOn(6, 32), throwsRangeError);
      expect(() => t.yearlyOn(6, 1, 'x'), throwsFormatException);
      expect(cron(t), '* * * * *');
    });

    test('yearlyOn rejects a day the month never has', () {
      expect(() => task().yearlyOn(2, 30), throwsRangeError);
      expect(() => task().yearlyOn(4, 31), throwsRangeError);
      expect(cron(task().yearlyOn(2, 29)), '0 0 29 2 *');
      expect(cron(task().yearlyOn(12, 31)), '0 0 31 12 *');
    });

    test('everyOddHour isDue', () {
      ScheduledTask t = task().everyOddHour();
      expect(t.isDue(DateTime.utc(2026, 1, 1, 1)), isTrue);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 23)), isTrue);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 2)), isFalse);
    });
  });

  group('lastDayOfMonth |', () {
    test('February, not a leap year', () {
      ScheduledTask t = task().lastDayOfMonth();
      expect(t.isDue(DateTime.utc(2026, 2, 28)), isTrue);
      expect(t.nextRun(DateTime.utc(2026, 2)), DateTime.utc(2026, 2, 28));
    });

    test('February, leap year', () {
      ScheduledTask t = task().lastDayOfMonth();
      expect(t.isDue(DateTime.utc(2028, 2, 28)), isFalse);
      expect(t.isDue(DateTime.utc(2028, 2, 29)), isTrue);
      expect(t.nextRun(DateTime.utc(2028, 2)), DateTime.utc(2028, 2, 29));
    });

    test('a 30 day month', () {
      ScheduledTask t = task().lastDayOfMonth('18:00');
      expect(t.isDue(DateTime.utc(2026, 4, 29, 18)), isFalse);
      expect(t.isDue(DateTime.utc(2026, 4, 30, 18)), isTrue);
      expect(t.nextRun(DateTime.utc(2026, 4)), DateTime.utc(2026, 4, 30, 18));
      // 31 days in May
      expect(
        t.nextRun(DateTime.utc(2026, 4, 30, 18)),
        DateTime.utc(2026, 5, 31, 18),
      );
    });

    test('in the task zone', () {
      // Asia/Yangon is UTC+06:30: Apr 30 00:00 there is Apr 29 17:30 UTC
      ScheduledTask t = task().lastDayOfMonth().timezone('Asia/Yangon');
      expect(t.isDue(DateTime.utc(2026, 4, 29, 17, 30)), isTrue);
      expect(
        t.nextRun(DateTime.utc(2026, 4)),
        DateTime.utc(2026, 4, 29, 17, 30),
      );
    });

    test('summer time day (Europe/London)', () {
      // 2027-10-31: 01:00 to 02:00 happens twice; it runs at the first one
      ScheduledTask twice = task().lastDayOfMonth('01:30');
      twice.timezone('Europe/London');
      expect(
        twice.nextRun(DateTime.utc(2027, 10)),
        DateTime.utc(2027, 10, 31, 0, 30),
      );
      // 2030-03-31: 01:00 to 02:00 is skipped, so March does not run
      ScheduledTask skipped = task().lastDayOfMonth('01:30');
      skipped.timezone('Europe/London');
      expect(
        skipped.nextRun(DateTime.utc(2030, 3)),
        DateTime.utc(2030, 4, 30, 0, 30),
      );
    });

    test('cron() ends it', () {
      ScheduledTask t = task().lastDayOfMonth().cron('0 0 28-31 * *');
      expect(t.isDue(DateTime.utc(2026, 4, 28)), isTrue);
    });

    test('a later day of month setter ends it', () {
      ScheduledTask t = task().lastDayOfMonth().monthlyOn(28);
      expect(t.isDue(DateTime.utc(2026, 4, 28)), isTrue);
    });
  });

  group('unlessBetween |', () {
    test('same day', () {
      ScheduledTask t = task().hourly().unlessBetween('09:00', '17:00');
      expect(t.isDue(DateTime.utc(2026, 1, 1, 8)), isTrue);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 9)), isFalse);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 17)), isFalse);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 18)), isTrue);
    });

    test('across midnight', () {
      ScheduledTask t = task().hourly().unlessBetween('22:00', '02:00');
      expect(t.isDue(DateTime.utc(2026, 1, 1, 21)), isTrue);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 23)), isFalse);
      expect(t.isDue(DateTime.utc(2026)), isFalse);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 2)), isFalse);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 3)), isTrue);
      expect(
        t.nextRun(DateTime.utc(2026, 1, 1, 21, 30)),
        DateTime.utc(2026, 1, 2, 3),
      );
    });

    test('with between', () {
      ScheduledTask t = task()
          .hourly()
          .between('08:00', '18:00')
          .unlessBetween('12:00', '13:00');
      expect(t.isDue(DateTime.utc(2026, 1, 1, 11)), isTrue);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 12)), isFalse);
      expect(
        t.nextRun(DateTime.utc(2026, 1, 1, 11, 30)),
        DateTime.utc(2026, 1, 1, 14),
      );
    });
  });

  group('environments |', () {
    tearDown(() {
      Env().env.remove('APP_ENV');
    });

    test('runs when APP_ENV is in the list', () async {
      Env().env['APP_ENV'] = ' Production ';
      ScheduledTask t = task().environments(<String>['staging', 'PRODUCTION']);
      expect(await t.filtersPass(), isTrue);
    });

    test('skips when APP_ENV is not in the list', () async {
      Env().env['APP_ENV'] = 'local';
      ScheduledTask t = task().environments(<String>['production']);
      expect(await t.filtersPass(), isFalse);
    });

    test('skips when APP_ENV is empty', () async {
      ScheduledTask t = task().environments(<String>['production']);
      expect(await t.filtersPass(), isFalse);
      Env().env['APP_ENV'] = '';
      expect(await t.filtersPass(), isFalse);
    });

    test('read at run time, not when built', () async {
      ScheduledTask t = task().environments(<String>['production']);
      expect(await t.filtersPass(), isFalse);
      Env().env['APP_ENV'] = 'production';
      expect(await t.filtersPass(), isTrue);
    });

    test('with when() and skip()', () async {
      Env().env['APP_ENV'] = 'production';
      bool skip = false;
      ScheduledTask t = task()
          .environments(<String>['production'])
          .when(() => true)
          .skip(() => skip);
      expect(await t.filtersPass(), isTrue);
      skip = true;
      expect(await t.filtersPass(), isFalse);
      skip = false;
      Env().env['APP_ENV'] = 'staging';
      expect(await t.filtersPass(), isFalse);
    });

    test('no environments: runs anywhere', () async {
      Env().env['APP_ENV'] = 'local';
      expect(await task().filtersPass(), isTrue);
    });
  });

  group('Schedule timezone |', () {
    test('null is UTC', () {
      Schedule s = Schedule();
      expect(s.call('a', noop).zone.isUtc, isTrue);
    });

    test('new tasks get the zone', () {
      Schedule s = Schedule(timezone: 'Asia/Yangon');
      ScheduledTask t = s.call('a', noop).dailyAt('02:00');
      expect(t.zone.name, 'Asia/Yangon');
      expect(t.nextRun(DateTime.utc(2026)), DateTime.utc(2026, 1, 1, 19, 30));
    });

    test('timezone() on the task wins', () {
      Schedule s = Schedule(timezone: 'Asia/Yangon');
      ScheduledTask t = s.call('a', noop).dailyAt('02:00').timezone('UTC');
      expect(t.zone.isUtc, isTrue);
      expect(t.isDue(DateTime.utc(2026, 1, 1, 2)), isTrue);
    });

    test('an unknown name throws', () {
      expect(() => Schedule(timezone: 'Mars/Base'), throwsArgumentError);
    });
  });
}
