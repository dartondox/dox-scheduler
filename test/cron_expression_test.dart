import 'package:dox_scheduler/dox_scheduler.dart';
import 'package:test/test.dart';

DateTime t(int y, int m, int d, [int h = 0, int min = 0]) {
  return DateTime.utc(y, m, d, h, min);
}

void main() {
  group('CronExpression parse |', () {
    test('star', () {
      CronExpression c = CronExpression('* * * * *');
      expect(c.minutes.length, 60);
      expect(c.hours.length, 24);
      expect(c.daysOfMonth.length, 31);
      expect(c.months.length, 12);
      expect(c.daysOfWeek, <int>{0, 1, 2, 3, 4, 5, 6});
    });

    test('numbers, ranges, lists and steps', () {
      CronExpression c = CronExpression('5,10-12,*/20 1-10/3 * * *');
      expect(c.minutes, <int>{0, 5, 10, 11, 12, 20, 40});
      expect(c.hours, <int>{1, 4, 7, 10});
    });

    test('a number with a step runs to the end', () {
      expect(CronExpression('50/5 * * * *').minutes, <int>{50, 55});
    });

    test('names, any case', () {
      CronExpression c = CronExpression('0 0 * jan-Mar,DEC MON-fri');
      expect(c.months, <int>{1, 2, 3, 12});
      expect(c.daysOfWeek, <int>{1, 2, 3, 4, 5});
    });

    test('7 is Sunday', () {
      expect(CronExpression('0 0 * * 7').daysOfWeek, <int>{0});
      expect(CronExpression('0 0 * * 5-7').daysOfWeek, <int>{5, 6, 0});
    });

    test('extra spaces', () {
      expect(CronExpression('  0   2 * *  * ').hours, <int>{2});
    });

    for (String bad in <String>[
      '',
      '* * * *',
      '* * * * * *',
      '60 * * * *',
      '* 24 * * *',
      '* * 0 * *',
      '* * 32 * *',
      '* * * 13 *',
      '* * * * 8',
      '5-1 * * * *',
      '*/0 * * * *',
      '*/x * * * *',
      'a * * * *',
      '1-2-3 * * * *',
      '*/2/3 * * * *',
      '* * * FOO *',
      '* * * * MON-',
    ]) {
      test('bad: "$bad"', () {
        expect(() => CronExpression(bad), throwsFormatException);
      });
    }
  });

  group('CronExpression matches |', () {
    test('every five minutes', () {
      CronExpression c = CronExpression('*/5 * * * *');
      expect(c.matches(t(2026, 1, 1, 3, 15)), isTrue);
      expect(c.matches(t(2026, 1, 1, 3, 16)), isFalse);
    });

    test('day of month OR day of week when both are set', () {
      // the 1st of the month, or any Monday
      CronExpression c = CronExpression('0 0 1 * MON');
      expect(c.matches(t(2026, 10, 1)), isTrue); // Thursday the 1st
      expect(c.matches(t(2026, 10, 26)), isTrue); // Monday
      expect(c.matches(t(2026, 10, 27)), isFalse); // Tuesday
    });

    test('AND when one day field starts with *', () {
      CronExpression c = CronExpression('0 0 * * MON');
      expect(c.matches(t(2026, 10, 1)), isFalse);
      expect(c.matches(t(2026, 10, 26)), isTrue);
      // `*/2` starts with *, so it is AND, like standard cron
      CronExpression odd = CronExpression('0 0 */2 * MON');
      expect(odd.matches(t(2026, 10, 26)), isFalse); // Monday the 26th
      expect(odd.matches(t(2026, 11, 9)), isTrue); // Monday the 9th
    });

    test('seconds are ignored', () {
      CronExpression c = CronExpression('30 2 * * *');
      expect(c.matches(DateTime.utc(2026, 1, 1, 2, 30, 59)), isTrue);
    });
  });

  group('CronExpression next |', () {
    test('same minute counts', () {
      expect(
        CronExpression('0 2 * * *').next(t(2026, 1, 1, 2)),
        t(2026, 1, 1, 2),
      );
    });

    test('seconds move to the next minute', () {
      expect(
        CronExpression('* * * * *').next(DateTime.utc(2026, 1, 1, 2, 0, 1)),
        t(2026, 1, 1, 2, 1),
      );
    });

    test('next day', () {
      expect(
        CronExpression('0 2 * * *').next(t(2026, 1, 1, 2, 1)),
        t(2026, 1, 2, 2),
      );
    });

    test('year end', () {
      expect(
        CronExpression('0 0 1 1 *').next(t(2026, 12, 31, 23, 59)),
        t(2027, 1, 1),
      );
    });

    test('31st skips short months', () {
      expect(CronExpression('0 0 31 * *').next(t(2026, 4, 1)), t(2026, 5, 31));
    });

    test('Feb 29 waits for a leap year', () {
      expect(CronExpression('0 0 29 2 *').next(t(2026, 3, 1)), t(2028, 2, 29));
    });

    test('Feb 30 never matches', () {
      expect(CronExpression('0 0 30 2 *').next(t(2026, 1, 1)), isNull);
    });

    test('Friday the 13th style OR rule', () {
      // the 13th or a Friday: Friday 2026-10-16 comes after the 13th
      CronExpression c = CronExpression('0 9 13 * FRI');
      expect(c.next(t(2026, 10, 10)), t(2026, 10, 13, 9));
      expect(c.next(t(2026, 10, 13, 10)), t(2026, 10, 16, 9));
    });

    test('weekdays at 9-17 every 15', () {
      CronExpression c = CronExpression('*/15 9-17 * * 1-5');
      // Friday 17:50 -> Monday 09:00
      expect(c.next(t(2026, 10, 23, 17, 50)), t(2026, 10, 26, 9));
    });
  });
}
