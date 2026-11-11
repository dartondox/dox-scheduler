import 'dart:async';

import 'package:dox_core/dox_core.dart' show Env;

import 'constants/schedule_constants.dart';
import 'cron_expression.dart';
import 'schedule_zone.dart';

/// The work of a task. It can return a Future, like a queue `dispatch()`.
typedef TaskCallback = FutureOr<void> Function();

/// A filter of `when()` and `skip()`.
typedef TaskFilter = FutureOr<bool> Function();

/// A hook of `onFailure()`.
typedef TaskErrorHook = FutureOr<void> Function(Object error, StackTrace stack);

/// A hook of `onOutput()`. It gets the output of the process.
typedef TaskOutputHook = FutureOr<void> Function(String output);

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

  /// Seconds between runs inside a due minute, set by `everySecond()` to
  /// `everyThirtySeconds()`. Null: once a minute.
  int? repeatSeconds;

  final List<TaskFilter> _when = <TaskFilter>[];
  final List<TaskFilter> _skip = <TaskFilter>[];

  /// `between()` windows: start and end minute of the day.
  final List<List<int>> _between = <List<int>>[];

  /// `unlessBetween()` windows: start and end minute of the day.
  final List<List<int>> _unlessBetween = <List<int>>[];

  /// `environments()` names, trimmed and in lower case. Null: any.
  List<String>? _environments;

  /// `lastDayOfMonth()`: the day field is `28-31`, and the day must also
  /// be the last one of its month.
  bool _lastDayOnly = false;

  /// Hooks.
  final List<TaskCallback> beforeHooks = <TaskCallback>[];
  final List<TaskCallback> afterHooks = <TaskCallback>[];
  final List<TaskCallback> successHooks = <TaskCallback>[];
  final List<TaskErrorHook> failureHooks = <TaskErrorHook>[];

  /// The file of `sendOutputTo()` or `appendOutputTo()`. Null: none.
  String? outputPath;

  /// True after `appendOutputTo()`: add to the file, do not replace it.
  bool appendOutput = false;

  /// `onOutput()` hooks.
  final List<TaskOutputHook> outputHooks = <TaskOutputHook>[];

  // ---------------------------------------------------------------------
  // Frequencies
  // ---------------------------------------------------------------------

  /// Any 5 field cron expression, like `*/5 * * * *`.
  ScheduledTask cron(String expression) {
    CronExpression parsed = CronExpression(expression);
    List<String> fields = parsed.expression.trim().split(RegExp(r'\s+'));
    _fields.setAll(0, fields);
    this.expression = parsed;
    _lastDayOnly = false;
    return this;
  }

  /// Every second. Like the other `every...Seconds()` methods, it sets
  /// the cron to every minute. Then the task repeats inside each due
  /// minute. Other frequencies, filters and `timezone()` still decide if
  /// a minute is due.
  ScheduledTask everySecond() {
    return _repeatEvery(1);
  }

  ScheduledTask everyTwoSeconds() {
    return _repeatEvery(2);
  }

  ScheduledTask everyFiveSeconds() {
    return _repeatEvery(5);
  }

  ScheduledTask everyTenSeconds() {
    return _repeatEvery(10);
  }

  ScheduledTask everyFifteenSeconds() {
    return _repeatEvery(15);
  }

  ScheduledTask everyTwentySeconds() {
    return _repeatEvery(20);
  }

  ScheduledTask everyThirtySeconds() {
    return _repeatEvery(30);
  }

  ScheduledTask everyMinute() {
    return _set(0, '*');
  }

  ScheduledTask everyTwoMinutes() {
    return _set(0, '*/2');
  }

  ScheduledTask everyThreeMinutes() {
    return _set(0, '*/3');
  }

  ScheduledTask everyFourMinutes() {
    return _set(0, '*/4');
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

  /// Every 2 hours, at [minute] of the hour.
  ScheduledTask everyTwoHours([int minute = 0]) {
    return _everyHours('*/2', minute);
  }

  /// Every 3 hours, at [minute] of the hour.
  ScheduledTask everyThreeHours([int minute = 0]) {
    return _everyHours('*/3', minute);
  }

  /// Every 4 hours, at [minute] of the hour.
  ScheduledTask everyFourHours([int minute = 0]) {
    return _everyHours('*/4', minute);
  }

  /// Every 6 hours, at [minute] of the hour.
  ScheduledTask everySixHours([int minute = 0]) {
    return _everyHours('*/6', minute);
  }

  /// Every odd hour (1, 3, ... 23), at [minute] of the hour.
  ScheduledTask everyOddHour([int minute = 0]) {
    return _everyHours('1-23/2', minute);
  }

  /// Every day at 00:00.
  ScheduledTask daily() {
    return dailyAt('00:00');
  }

  /// Every day at [time], like `'02:00'`. An hour alone (`'13'`) is 13:00.
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

  /// Every day at [first]:[minute] and [second]:[minute].
  ScheduledTask twiceDailyAt([int first = 1, int second = 13, int minute = 0]) {
    _check(minute, 0, 59, 'minute');
    twiceDaily(first, second);
    return _set(0, '$minute');
  }

  /// Same as `dailyAt()`: sets the hour and the minute only.
  ScheduledTask at(String time) {
    return dailyAt(time);
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

  /// The last day of every month at [time].
  ScheduledTask lastDayOfMonth([String time = '00:00']) {
    // ponytail: no `L` in the cron parser. 28-31 plus a check that
    // tomorrow is a new month, in isDue and nextRun.
    _set(2, '28-31');
    dailyAt(time);
    _lastDayOnly = true;
    return this;
  }

  /// Every month on day [first] and day [second] at [time].
  ScheduledTask twiceMonthly([
    int first = 1,
    int second = 16,
    String time = '00:00',
  ]) {
    _check(first, 1, 31, 'day');
    _check(second, 1, 31, 'day');
    _set(2, '$first,$second');
    return dailyAt(time);
  }

  /// January, April, July and October 1st at 00:00.
  ScheduledTask quarterly() {
    return quarterlyOn();
  }

  /// January, April, July and October on [day] at [time].
  ScheduledTask quarterlyOn([int day = 1, String time = '00:00']) {
    // check first, so a bad value does not leave a half set task
    _check(day, 1, 31, 'day');
    _time(time);
    _set(3, '1,4,7,10');
    return monthlyOn(day, time);
  }

  /// January 1st at 00:00.
  ScheduledTask yearly() {
    _set(3, '1');
    return monthlyOn(1);
  }

  /// Every year on [month] (1-12) and [day] at [time]. A day that the
  /// month never has, like February 30, throws. February 29 runs in leap
  /// years only.
  ScheduledTask yearlyOn([int month = 1, int day = 1, String time = '00:00']) {
    _check(month, 1, 12, 'month');
    // 2028 is a leap year, so February has 29 days
    _check(day, 1, DateTime.utc(2028, month + 1, 0).day, 'day');
    _time(time);
    _set(3, '$month');
    return monthlyOn(day, time);
  }

  /// Monday to Friday only.
  ScheduledTask weekdays() {
    return _set(4, '1-5');
  }

  /// Saturday and Sunday only.
  ScheduledTask weekends() {
    return _set(4, '0,6');
  }

  /// Mondays only.
  ScheduledTask mondays() {
    return days(<int>[DateTime.monday]);
  }

  /// Tuesdays only.
  ScheduledTask tuesdays() {
    return days(<int>[DateTime.tuesday]);
  }

  /// Wednesdays only.
  ScheduledTask wednesdays() {
    return days(<int>[DateTime.wednesday]);
  }

  /// Thursdays only.
  ScheduledTask thursdays() {
    return days(<int>[DateTime.thursday]);
  }

  /// Fridays only.
  ScheduledTask fridays() {
    return days(<int>[DateTime.friday]);
  }

  /// Saturdays only.
  ScheduledTask saturdays() {
    return days(<int>[DateTime.saturday]);
  }

  /// Sundays only.
  ScheduledTask sundays() {
    return days(<int>[DateTime.sunday]);
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
  /// [end], both included. `between('22:00', '06:00')` crosses midnight. An hour
  /// alone works too: `between('9', '17')` is 09:00 to 17:00.
  ScheduledTask between(String start, String end) {
    _between.add(_window(start, end));
    return this;
  }

  /// Do not run when the time of day (in the task zone) is from [start] to
  /// [end], both included. The opposite of `between()`. It can cross
  /// midnight too: `unlessBetween('23:00', '04:00')`.
  ScheduledTask unlessBetween(String start, String end) {
    _unlessBetween.add(_window(start, end));
    return this;
  }

  /// Run only when the `APP_ENV` env value is one of [names], like
  /// `environments(['production'])`. Case and spaces do not matter. It is
  /// checked at run time, with `when()` and `skip()`.
  ScheduledTask environments(List<String> names) {
    if (names.isEmpty) {
      throw ArgumentError.value(names, 'names', 'Give at least one name');
    }
    List<String> clean = <String>[
      for (String name in names) name.trim().toLowerCase(),
    ];
    // a blank name would match a missing APP_ENV
    if (clean.contains('')) {
      throw ArgumentError.value(names, 'names', 'A name can not be blank');
    }
    _environments = clean;
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

  /// Write the output (stdout, then stderr) of an `exec()` or
  /// `command()` task to the file at [path]. It replaces the file each
  /// run. A callback task has no output, so this does nothing there.
  ScheduledTask sendOutputTo(String path) {
    outputPath = path;
    appendOutput = false;
    return this;
  }

  /// Like `sendOutputTo()`, but adds the output to the end of the file.
  ScheduledTask appendOutputTo(String path) {
    outputPath = path;
    appendOutput = true;
    return this;
  }

  /// Call [hook] with the output (stdout, then stderr) of an `exec()` or
  /// `command()` task, after the process ends and before the success or
  /// failure hooks. A throwing hook fails the task. A callback task has
  /// no output, so the hook is never called there.
  ScheduledTask onOutput(TaskOutputHook hook) {
    outputHooks.add(hook);
    return this;
  }

  // ---------------------------------------------------------------------
  // Checks
  // ---------------------------------------------------------------------

  /// True when the cron expression, `between()`, `unlessBetween()` and
  /// `lastDayOfMonth()` match the minute [tick] (a UTC moment).
  bool isDue(DateTime tick) {
    DateTime wall = zone.wall(tick);
    if (!expression.matches(wall)) return false;
    // a wall time that happens twice runs only at its first moment
    DateTime? moment = zone.instant(wall);
    if (moment == null || !_sameMinute(moment, tick)) return false;
    return _inWindows(wall);
  }

  /// True when `APP_ENV` is one of `environments()`, every `when()`
  /// filter gives true and no `skip()` filter does.
  Future<bool> filtersPass() async {
    List<String>? names = _environments;
    if (names != null &&
        !names.contains(Env.get<String>('APP_ENV').trim().toLowerCase())) {
      return false;
    }
    for (TaskFilter filter in _when) {
      if (!await filter()) return false;
    }
    for (TaskFilter filter in _skip) {
      if (await filter()) return false;
    }
    return true;
  }

  /// The next moment (UTC) after [from] when the cron expression,
  /// `between()`, `unlessBetween()` and `lastDayOfMonth()` match.
  /// `when()` and `skip()` are not checked. Null when it never runs.
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

  /// The `between()`, `unlessBetween()` and `environments()` filters as
  /// text, like `between 09:00-17:00, env production`. Empty when the
  /// task has none. `when()` and `skip()` are code, so they are not in it.
  String describeFilters() {
    return <String>[
      if (repeatSeconds case int seconds) 'every ${seconds}s',
      for (List<int> window in _between) 'between ${_windowText(window)}',
      for (List<int> window in _unlessBetween)
        'unless between ${_windowText(window)}',
      if (_environments case List<String> names) 'env ${names.join('|')}',
    ].join(', ');
  }

  /// like `09:00-17:00`
  static String _windowText(List<int> window) {
    String time(int minute) {
      String hour = '${minute ~/ 60}'.padLeft(2, '0');
      return '$hour:${'${minute % 60}'.padLeft(2, '0')}';
    }

    return '${time(window[0])}-${time(window[1])}';
  }

  /// The checks of a wall time that cron can not do.
  bool _inWindows(DateTime wall) {
    if (_lastDayOnly &&
        DateTime.utc(wall.year, wall.month, wall.day + 1).month == wall.month) {
      return false;
    }
    int minute = wall.hour * 60 + wall.minute;
    if (_inAny(_unlessBetween, minute)) return false;
    return _between.isEmpty || _inAny(_between, minute);
  }

  static bool _inAny(List<List<int>> windows, int minute) {
    for (List<int> window in windows) {
      int start = window[0];
      int end = window[1];
      bool inside = start <= end
          ? minute >= start && minute <= end
          : minute >= start || minute <= end;
      if (inside) return true;
    }
    return false;
  }

  static List<int> _window(String start, String end) {
    List<int> from = _time(start);
    List<int> to = _time(end);
    return <int>[from[0] * 60 + from[1], to[0] * 60 + to[1]];
  }

  /// like Laravel: every minute, and [seconds] between runs
  ScheduledTask _repeatEvery(int seconds) {
    repeatSeconds = seconds;
    return everyMinute();
  }

  ScheduledTask _everyHours(String hours, int minute) {
    _check(minute, 0, 59, 'minute');
    _set(1, hours);
    return _set(0, '$minute');
  }

  ScheduledTask _set(int position, String value) {
    // a new day of month ends lastDayOfMonth()
    if (position == 2) _lastDayOnly = false;
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
    // an hour alone ('13') is 13:00, like Laravel
    if (parts.length == 1) parts.add('0');
    int? hour = parts.length == 2 ? int.tryParse(parts[0]) : null;
    int? minute = parts.length == 2 ? int.tryParse(parts[1]) : null;
    if (hour == null || minute == null) {
      throw FormatException('Time must be HH:mm or HH', time);
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
