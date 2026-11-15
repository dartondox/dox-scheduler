import 'dart:io';

import 'package:dox_core/dox_core.dart' show Dox, Logger, LoggerConfig;

/// The level of a scheduler log line. The names match `Logger`.
enum SchedulerLogLevel { info, success, warn, danger }

/// Internal. Writes one scheduler line to a sink and to the `Logger`.
/// Not exported from the package.
class SchedulerLog {
  /// The tag of every scheduler line in the `Logger`.
  static const String tag = 'scheduler';

  /// Write [plain] to [sink], and log [message] with the tag
  /// `[scheduler]` when the app has the Logger on (and the level lets
  /// the line through). The Logger writes to stdout. So when [sink] is
  /// stdout or stderr and the Logger prints the line, [plain] is not
  /// written: the line would show twice in the terminal. Any other sink
  /// (like a `StringBuffer` in a test) always gets [plain].
  static void write(
    StringSink sink,
    SchedulerLogLevel level,
    String plain,
    String message,
  ) {
    bool logged = _prints(level);
    if (logged) Logger.log(level.name, message, null, tag);
    if (logged && (identical(sink, stdout) || identical(sink, stderr))) {
      return;
    }
    sink.writeln(plain);
  }

  /// True when the Logger prints a line of [level].
  static bool _prints(SchedulerLogLevel level) {
    LoggerConfig config;
    try {
      config = Dox().config.logger;
    } on Error {
      // ponytail: no app config yet (Dox not initialized), so no Logger
      return false;
    }
    return config.enabled && Logger.shouldLog(level.name, config.level);
  }
}
