/// Fixed values of the scheduler.
class ScheduleConstants {
  /// Start of every lock name, so the locks do not clash with app keys.
  static const String lockPrefix = 'dox_schedule:';

  /// How long the once-per-tick lock lives. It is never released, so a
  /// late server can not run the same tick again. It must be longer than
  /// the clock gap between your servers.
  static const Duration tickLockTtl = Duration(minutes: 10);

  /// Default expiry of the `withoutOverlapping()` lock. A crashed process
  /// can not hold it longer than this.
  static const Duration overlapLockTtl = Duration(hours: 24);

  /// Exit code for a wrong command line.
  static const int usageExitCode = 64;

  /// The time zone of a task that does not call `timezone()`.
  static const String utc = 'UTC';

  /// `next` looks this many years ahead before it gives up
  /// (`0 0 30 2 *` never matches).
  static const int maxYearsAhead = 30;
}
