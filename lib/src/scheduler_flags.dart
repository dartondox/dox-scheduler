/// Opt-in behaviors that change the defaults. Every flag is off by default.
/// Pass it as `ScheduleConfig(flags: ...)`.
/// ```
/// ScheduleConfig(flags: const SchedulerFlags(loggerLines: true));
/// ScheduleConfig(flags: const SchedulerFlags.all());
/// ```
/// The scheduler reads them when the code runs.
class SchedulerFlags {
  const SchedulerFlags({this.loggerLines = false});

  /// Every flag on.
  const SchedulerFlags.all() : loggerLines = true;

  /// The scheduler logs its lines through the app `Logger`, with the tag
  /// `[scheduler]`, like `[scheduler] ran cleanup in 12ms`. They follow
  /// `LoggerConfig.enabled`, `level` and `prettyPrint`. A sink that is
  /// stdout or stderr skips the plain `[schedule]` line when the Logger
  /// wrote it, so the line does not show twice. Then the lock store
  /// warning goes to stdout (through the Logger), not to stderr. Other
  /// sinks still get every plain line. Off: only the plain lines.
  // NEXT MAJOR: make this the default, then remove the flag.
  final bool loggerLines;
}
