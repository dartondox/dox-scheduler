import 'constants/schedule_constants.dart';

/// A standard 5 field cron expression:
/// `minute hour day-of-month month day-of-week`.
///
/// Each field takes `*`, a number, a range `1-5`, a list `1,3,5`, and a
/// step `*/15` or `1-30/5`. Months take `JAN`-`DEC`, days of the week
/// take `SUN`-`SAT` (0 and 7 are both Sunday).
///
/// Like standard cron: when both day-of-month and day-of-week are set
/// (neither starts with `*`), a day matches when **either** matches.
///
/// ```
/// CronExpression cron = CronExpression('*/5 9-17 * * MON-FRI');
/// cron.matches(DateTime.utc(2026, 10, 26, 9, 5)); // true
/// ```
class CronExpression {
  CronExpression(this.expression) {
    List<String> fields = expression.trim().split(RegExp(r'\s+'));
    if (fields.length != 5) {
      throw FormatException(
        'A cron expression needs 5 fields '
        '(minute hour day-of-month month day-of-week)',
        expression,
      );
    }
    minutes = _parse(fields[0], 0, 59, null);
    hours = _parse(fields[1], 0, 23, null);
    daysOfMonth = _parse(fields[2], 1, 31, null);
    months = _parse(fields[3], 1, 12, _monthNames);
    Set<int> week = _parse(fields[4], 0, 7, _dayNames);
    if (week.remove(7)) week.add(0);
    daysOfWeek = week;
    _anyDayOfMonth = fields[2].startsWith('*');
    _anyDayOfWeek = fields[4].startsWith('*');
  }

  /// The text this was made from.
  final String expression;

  /// 0-59
  late final Set<int> minutes;

  /// 0-23
  late final Set<int> hours;

  /// 1-31
  late final Set<int> daysOfMonth;

  /// 1-12
  late final Set<int> months;

  /// 0-6, 0 is Sunday
  late final Set<int> daysOfWeek;

  late final bool _anyDayOfMonth;
  late final bool _anyDayOfWeek;

  static const Map<String, int> _monthNames = <String, int>{
    'JAN': 1,
    'FEB': 2,
    'MAR': 3,
    'APR': 4,
    'MAY': 5,
    'JUN': 6,
    'JUL': 7,
    'AUG': 8,
    'SEP': 9,
    'OCT': 10,
    'NOV': 11,
    'DEC': 12,
  };

  static const Map<String, int> _dayNames = <String, int>{
    'SUN': 0,
    'MON': 1,
    'TUE': 2,
    'WED': 3,
    'THU': 4,
    'FRI': 5,
    'SAT': 6,
  };

  /// True when the wall clock time [time] matches. Only its year, month,
  /// day, hour and minute fields are read (seconds are ignored).
  bool matches(DateTime time) {
    return months.contains(time.month) &&
        _dayMatches(time) &&
        hours.contains(time.hour) &&
        minutes.contains(time.minute);
  }

  /// The first matching wall clock minute at or after [from], as a UTC
  /// [DateTime] that holds wall clock fields. Null when nothing matches
  /// in the next 30 years (like `0 0 30 2 *`).
  DateTime? next(DateTime from) {
    DateTime t = DateTime.utc(
      from.year,
      from.month,
      from.day,
      from.hour,
      from.minute,
    );
    if (from.second > 0 || from.millisecond > 0 || from.microsecond > 0) {
      t = t.add(const Duration(minutes: 1));
    }
    DateTime limit = DateTime.utc(t.year + ScheduleConstants.maxYearsAhead);
    while (t.isBefore(limit)) {
      if (!months.contains(t.month)) {
        t = DateTime.utc(t.year, t.month + 1);
      } else if (!_dayMatches(t)) {
        t = DateTime.utc(t.year, t.month, t.day + 1);
      } else if (!hours.contains(t.hour)) {
        t = DateTime.utc(t.year, t.month, t.day, t.hour + 1);
      } else if (!minutes.contains(t.minute)) {
        t = t.add(const Duration(minutes: 1));
      } else {
        return t;
      }
    }
    return null;
  }

  @override
  String toString() {
    return expression;
  }

  bool _dayMatches(DateTime time) {
    bool dayOfMonth = daysOfMonth.contains(time.day);
    bool dayOfWeek = daysOfWeek.contains(time.weekday % 7);
    if (_anyDayOfMonth || _anyDayOfWeek) {
      return dayOfMonth && dayOfWeek;
    }
    return dayOfMonth || dayOfWeek;
  }

  Set<int> _parse(String field, int min, int max, Map<String, int>? names) {
    Set<int> values = <int>{};
    for (String part in field.split(',')) {
      List<String> stepParts = part.split('/');
      if (stepParts.length > 2) _fail(field);
      String range = stepParts[0];
      int step = 1;
      if (stepParts.length == 2) {
        step = int.tryParse(stepParts[1]) ?? 0;
        if (step < 1) _fail(field);
      }
      int start;
      int end;
      if (range == '*') {
        start = min;
        end = max;
      } else if (range.contains('-')) {
        List<String> ends = range.split('-');
        if (ends.length != 2) _fail(field);
        start = _value(ends[0], field, names);
        end = _value(ends[1], field, names);
      } else {
        start = _value(range, field, names);
        // `5/15` means from 5 to the end, every 15
        end = stepParts.length == 2 ? max : start;
      }
      if (start < min || end > max || start > end) _fail(field);
      for (int v = start; v <= end; v += step) {
        values.add(v);
      }
    }
    return values;
  }

  int _value(String text, String field, Map<String, int>? names) {
    int? named = names?[text.toUpperCase()];
    int? value = named ?? int.tryParse(text);
    if (value == null) _fail(field);
    return value;
  }

  Never _fail(String field) {
    throw FormatException('Bad cron field "$field"', expression);
  }
}
