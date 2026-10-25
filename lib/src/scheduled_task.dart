import 'dart:async';

import 'constants/schedule_constants.dart';
import 'cron_expression.dart';
import 'schedule_zone.dart';

/// The work of a task. It can return a Future, like a queue `dispatch()`.
typedef TaskCallback = FutureOr<void> Function();

/// A filter of `when()` and `skip()`.
typedef TaskFilter = FutureOr<bool> Function();

/// A hook of `onFailure()`.
typedef TaskErrorHook = FutureOr<void> Function(Object error, StackTrace stack);

/// One task of the schedule. Made by `Schedule.call()`.
///
/// It runs every minute until you set a frequency:
/// ```
/// s.call('cleanup', cleanup).dailyAt('02:00').withoutOverlapping();
/// ```
class ScheduledTask {
  ScheduledTask(this.name, this.callback);

  /// Unique name. It is in the logs and the lock keys.
  final String name;

  /// The work.
  final TaskCallback callback;

  final List<String> _fields = <String>['*', '*', '*', '*', '*'];

  /// The cron expression of the task.
  CronExpression expression = CronExpression('* * * * *');

  /// The time zone of the cron expression. UTC by default.
  ScheduleZone zone = ScheduleZone.utc();

  /// Runs once per tick across isolates and servers. On by default.
  bool oneServer = true;

  /// Lock expiry of `withoutOverlapping()`. Null: overlapping is allowed.
  Duration? overlapExpiresAfter;

  /// Do not wait for this task before the next task of the same tick.
  bool background = false;

  /// Max run time of `timeout()`. Null: no limit.
  Duration? timeoutAfter;

  final List<TaskFilter> _when = <TaskFilter>[];
  final List<TaskFilter> _skip = <TaskFilter>[];

  /// `between()` windows: start and end minute of the day.
  final List<List<int>> _between = <List<int>>[];

  /// Hooks.
  final List<TaskCallback> beforeHooks = <TaskCallback>[];
  final List<TaskCallback> afterHooks = <TaskCallback>[];
  final List<TaskCallback> successHooks = <TaskCallback>[];
  final List<TaskErrorHook> failureHooks = <TaskErrorHook>[];

  // ---------------------------------------------------------------------
  // Frequencies
  // ---------------------------------------------------------------------

  /// Any 5 field cron expression, like `*/5 * * * *`.
  ScheduledTask cron(String expression) {
    CronExpression parsed = CronExpression(expression);
    List<String> fields = parsed.expression.trim().split(RegExp(r'\s+'));
    _fields.setAll(0, fields);
    this.expression = parsed;
    return this;
  }

  ScheduledTask everyMinute() {
    return _set(0, '*');
  }

  ScheduledTask everyTwoMinutes() {
    return _set(0, '*/2');
  }

  ScheduledTask everyFiveMinutes() {
    return _set(0, '*/5');
  }

  ScheduledTask everyTenMinutes() {
    return _set(0, '*/10');
  }

  ScheduledTask everyFifteenMinutes() {
    return _set(0, '*/15');
  }

  ScheduledTask everyThirtyMinutes() {
    return _set(0, '0,30');
  }

  /// At minute 0 of every hour.
  ScheduledTask hourly() {
    return _set(0, '0');
  }

  /// At [minute] of every hour.
  ScheduledTask hourlyAt(int minute) {
    _check(minute, 0, 59, 'minute');
    return _set(0, '$minute');
  }

  /// Every day at 00:00.
  ScheduledTask daily() {
    return dailyAt('00:00');
  }

  /// Every day at [time], like `'02:00'`.
  ScheduledTask dailyAt(String time) {
    List<int> hm = _time(time);
    _set(1, '${hm[0]}');
    return _set(0, '${hm[1]}');
  }

  /// Every day at [first]:00 and [second]:00.
  ScheduledTask twiceDaily([int first = 1, int second = 13]) {
    _check(first, 0, 23, 'hour');
    _check(second, 0, 23, 'hour');
    _set(1, '$first,$second');
    return _set(0, '0');
  }

  /// Every Sunday at 00:00.
  ScheduledTask weekly() {
    return weeklyOn(DateTime.sunday);
  }

  /// Every week on [day] at [time]. [day] is `DateTime.monday` to
  /// `DateTime.sunday` (or 0 for Sunday).
  ScheduledTask weeklyOn(int day, [String time = '00:00']) {
    _check(day, 0, 7, 'day');
    _set(4, '${day % 7}');
    return dailyAt(time);
  }

  /// The first day of every month at 00:00.
  ScheduledTask monthly() {
    return monthlyOn(1);
  }

  /// Every month on [day] (1-31) at [time].
  ScheduledTask monthlyOn(int day, [String time = '00:00']) {
    _check(day, 1, 31, 'day');
    _set(2, '$day');
    return dailyAt(time);
  }

  /// January 1st at 00:00.
  ScheduledTask yearly() {
    _set(3, '1');
    return monthlyOn(1);
  }

  /// Monday to Friday only.
  ScheduledTask weekdays() {
    return _set(4, '1-5');
  }

  /// Saturday and Sunday only.
  ScheduledTask weekends() {
    return _set(4, '0,6');
  }

  /// Only on these days: `DateTime.monday` to `DateTime.sunday`.
  ScheduledTask days(List<int> days) {
    for (int day in days) {
      _check(day, 0, 7, 'day');
    }
    List<int> cronDays = <int>[for (int day in days) day % 7];
    return _set(4, cronDays.join(','));
  }

  /// Read the cron fields in this time zone, like `Asia/Yangon`.
  /// UTC by default. With summer time, a skipped time does not run, and a
  /// time that happens twice runs once.
  ScheduledTask timezone(String name) {
    zone = ScheduleZone(name);
    return this;
  }

  // ---------------------------------------------------------------------
  // Filters
  // ---------------------------------------------------------------------

  /// Run only when the time of day (in the task zone) is from [start] to
  /// [end], both included. `between('22:00', '06:00')` crosses midnight.
  ScheduledTask between(String start, String end) {
    List<int> from = _time(start);
    List<int> to = _time(end);
    _between.add(<int>[from[0] * 60 + from[1], to[0] * 60 + to[1]]);
    return this;
  }

  /// Run only when [filter] gives true.
  ScheduledTask when(TaskFilter filter) {
    _when.add(filter);
    return this;
  }

  /// Do not run when [filter] gives true.
  ScheduledTask skip(TaskFilter filter) {
    _skip.add(filter);
    return this;
  }

  // ---------------------------------------------------------------------
  // Options
  // ---------------------------------------------------------------------

  /// Do not start while the last run still runs. A lock is held while the
  /// task runs. It expires after [expiresAfter], in case a process dies.
  ScheduledTask withoutOverlapping([
    Duration expiresAfter = ScheduleConstants.overlapLockTtl,
  ]) {
    overlapExpiresAfter = expiresAfter;
    return this;
  }

  /// Run once per tick across isolates and servers. This is the default.
  /// Many servers need a shared lock store, like Redis.
  ScheduledTask onOneServer() {
    oneServer = true;
    return this;
  }

  /// Run on every server (and every runner) that runs the schedule.
  ScheduledTask onEveryServer() {
    oneServer = false;
    return this;
  }

  /// Do not wait for this task before the next task of the same tick.
  ScheduledTask runInBackground() {
    background = true;
    return this;
  }

  /// Count the run as failed when it takes longer than [duration].
  /// Dart can not stop a running function, so the work may go on.
  ScheduledTask timeout(Duration duration) {
    timeoutAfter = duration;
    return this;
  }

  // ---------------------------------------------------------------------
  // Hooks
  // ---------------------------------------------------------------------

  /// Runs before the task.
  ScheduledTask before(TaskCallback hook) {
    beforeHooks.add(hook);
    return this;
  }

  /// Runs after the task, also when it failed.
  ScheduledTask after(TaskCallback hook) {
    afterHooks.add(hook);
    return this;
  }

  /// Runs after the task when it worked.
  ScheduledTask onSuccess(TaskCallback hook) {
    successHooks.add(hook);
    return this;
  }

  /// Runs when the task (or a `before` hook) throws or times out.
  ScheduledTask onFailure(TaskErrorHook hook) {
    failureHooks.add(hook);
    return this;
  }

  // ---------------------------------------------------------------------
  // Checks
  // ---------------------------------------------------------------------

  /// True when the cron expression and `between()` match the minute
  /// [tick] (a UTC moment).
  bool isDue(DateTime tick) {
    DateTime wall = zone.wall(tick);
    if (!expression.matches(wall)) return false;
    // a wall time that happens twice runs only at its first moment
    DateTime? moment = zone.instant(wall);
    if (moment == null || !_sameMinute(moment, tick)) return false;
    return _inWindows(wall);
  }

  /// True when every `when()` filter gives true and no `skip()` filter
  /// does.
  Future<bool> filtersPass() async {
    for (TaskFilter filter in _when) {
      if (!await filter()) return false;
    }
    for (TaskFilter filter in _skip) {
      if (await filter()) return false;
    }
    return true;
  }

  /// The next moment (UTC) after [from] when the cron expression and
  /// `between()` match. `when()` and `skip()` are not checked. Null when
  /// it never runs.
  DateTime? nextRun(DateTime from) {
    DateTime wall = zone.wall(from);
    DateTime cursor = DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
    ).add(const Duration(minutes: 1));
    while (true) {
      DateTime? found = expression.next(cursor);
      // between() may never match the cron times
      if (found == null ||
          found.year > wall.year + ScheduleConstants.maxYearsAhead) {
        return null;
      }
      DateTime? moment = zone.instant(found);
      if (moment != null && moment.isAfter(from) && _inWindows(found)) {
        return moment;
      }
      cursor = found.add(const Duration(minutes: 1));
    }
  }

  /// The schedule as text, like `0 2 * * * Asia/Yangon`.
  String describe() {
    return zone.isUtc ? expression.expression : '$expression ${zone.name}';
  }

  bool _inWindows(DateTime wall) {
    if (_between.isEmpty) return true;
    int minute = wall.hour * 60 + wall.minute;
    for (List<int> window in _between) {
      int start = window[0];
      int end = window[1];
      bool inside = start <= end
          ? minute >= start && minute <= end
          : minute >= start || minute <= end;
      if (inside) return true;
    }
    return false;
  }

  ScheduledTask _set(int position, String value) {
    _fields[position] = value;
    expression = CronExpression(_fields.join(' '));
    return this;
  }

  static bool _sameMinute(DateTime a, DateTime b) {
    return a.millisecondsSinceEpoch ~/ 60000 ==
        b.millisecondsSinceEpoch ~/ 60000;
  }

  static List<int> _time(String time) {
    List<String> parts = time.split(':');
    int? hour = parts.length == 2 ? int.tryParse(parts[0]) : null;
    int? minute = parts.length == 2 ? int.tryParse(parts[1]) : null;
    if (hour == null || minute == null) {
      throw FormatException('Time must be HH:mm', time);
    }
    _check(hour, 0, 23, 'hour');
    _check(minute, 0, 59, 'minute');
    return <int>[hour, minute];
  }

  static void _check(int value, int min, int max, String name) {
    if (value < min || value > max) {
      throw RangeError.range(value, min, max, name);
    }
  }
}
