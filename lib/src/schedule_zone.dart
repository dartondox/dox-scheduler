import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'constants/schedule_constants.dart';

/// A time zone for a task: `UTC` or an IANA name like `Asia/Yangon`.
///
/// It turns a real moment into wall clock time and back. Wall clock times
/// are kept in UTC [DateTime] values that hold the local fields.
class ScheduleZone {
  /// [name] is `UTC` or an IANA name. Throws an [ArgumentError] for an
  /// unknown name.
  ScheduleZone(this.name) : _location = _find(name);

  /// The UTC zone.
  ScheduleZone.utc() : name = ScheduleConstants.utc, _location = null;

  final String name;

  /// null for UTC
  final tz.Location? _location;

  static bool _loaded = false;

  /// True for UTC.
  bool get isUtc {
    return _location == null;
  }

  /// The wall clock time of the moment [instant] in this zone.
  DateTime wall(DateTime instant) {
    tz.Location? location = _location;
    if (location == null) return instant.toUtc();
    tz.TZDateTime local = tz.TZDateTime.from(instant, location);
    return DateTime.utc(
      local.year,
      local.month,
      local.day,
      local.hour,
      local.minute,
      local.second,
      local.millisecond,
    );
  }

  /// The real moment (UTC) of the wall clock time [wall]. Null when the
  /// time does not exist in this zone (it is skipped by a summer time
  /// change). For a time that happens twice, the first one.
  DateTime? instant(DateTime wall) {
    tz.Location? location = _location;
    if (location == null) return wall;
    tz.TZDateTime local = tz.TZDateTime(
      location,
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
    );
    bool same =
        local.year == wall.year &&
        local.month == wall.month &&
        local.day == wall.day &&
        local.hour == wall.hour &&
        local.minute == wall.minute;
    if (!same) return null;
    // the first of two same wall times: one hour earlier is the same too
    DateTime first = local.toUtc();
    DateTime earlier = first.subtract(const Duration(hours: 1));
    tz.TZDateTime check = tz.TZDateTime.from(earlier, location);
    if (check.hour == wall.hour && check.minute == wall.minute) {
      return earlier;
    }
    return first;
  }

  static tz.Location? _find(String name) {
    if (name.toUpperCase() == ScheduleConstants.utc) return null;
    if (!_loaded) {
      tzdata.initializeTimeZones();
      _loaded = true;
    }
    try {
      return tz.getLocation(name);
    } on tz.LocationNotFoundException {
      throw ArgumentError.value(name, 'timezone', 'Unknown time zone');
    }
  }
}
