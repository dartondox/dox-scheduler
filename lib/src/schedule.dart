import 'dart:io';

import 'schedule_zone.dart';
import 'scheduled_task.dart';

/// The list of tasks. Your `schedule()` function fills it:
/// ```
/// void schedule(Schedule s) {
///   s.call('cleanup', cleanup).dailyAt('02:00');
///   s.call('report', sendReport).hourly();
/// }
/// ```
class Schedule {
  /// [timezone] is the default zone of new tasks, like `Asia/Yangon`.
  /// Null: UTC. Throws an [ArgumentError] for an unknown name.
  Schedule({String? timezone})
    : zone = timezone == null ? null : ScheduleZone(timezone);

  /// The default zone of new tasks. Null: UTC.
  final ScheduleZone? zone;

  /// The `dox` CLI that `command()` runs. Default: `dox` from PATH. Set
  /// a full path when the scheduler runs where `dox` is not on PATH.
  static String doxExecutable = 'dox';

  final List<ScheduledTask> _tasks = <ScheduledTask>[];

  /// The tasks, in the order they were added.
  List<ScheduledTask> get tasks {
    return List<ScheduledTask>.unmodifiable(_tasks);
  }

  /// Add a task with a unique [name] that runs [callback]. It runs every
  /// minute until you set a frequency on the result.
  ScheduledTask call(String name, TaskCallback callback) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'A task needs a name');
    }
    if (find(name) != null) {
      throw ArgumentError.value(name, 'name', 'Two tasks have this name');
    }
    ScheduledTask task = ScheduledTask(name, callback);
    ScheduleZone? defaultZone = zone;
    if (defaultZone != null) task.zone = defaultZone;
    _tasks.add(task);
    return task;
  }

  /// Add a task that runs [executable] with [args] as a process. No
  /// shell is used, so `|`, `>` and `*` are plain text. Use
  /// `exec('sh', ['-c', '...'])` when you need a shell. The task name is
  /// the command line, like `php artisan inspire`. A non-zero exit code
  /// fails the task.
  ScheduledTask exec(
    String executable, [
    List<String> args = const <String>[],
  ]) {
    List<String> argList = List<String>.of(args);
    late ScheduledTask task;
    task = call(
      <String>[executable, ...argList].join(' '),
      () => _runProcess(task, executable, argList),
    );
    return task;
  }

  /// Add a task that runs a `dox` command of the app, like
  /// `command('queue:prune', ['--hours=48'])`. It runs the process
  /// `dox queue:prune --hours=48` in the current folder (see
  /// [doxExecutable]). The task name is that command line.
  ScheduledTask command(
    String command, [
    List<String> args = const <String>[],
  ]) {
    return exec(doxExecutable, <String>[command, ...args]);
  }

  /// The task named [name], or null.
  ScheduledTask? find(String name) {
    for (ScheduledTask task in _tasks) {
      if (task.name == name) return task;
    }
    return null;
  }
}

/// run the process and hand its output to the output hooks of [task].
/// A non-zero exit code throws.
Future<void> _runProcess(
  ScheduledTask task,
  String executable,
  List<String> args,
) async {
  ProcessResult result = await Process.run(executable, args);
  // ponytail: stdout then stderr, not mixed in time like `2>&1`
  String output = '${result.stdout}${result.stderr}';
  String? path = task.outputPath;
  if (path != null) {
    FileMode mode = task.appendOutput ? FileMode.append : FileMode.write;
    await File(path).writeAsString(output, mode: mode);
  }
  for (TaskOutputHook hook in task.outputHooks) {
    await hook(output);
  }
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      args,
      'Exit code ${result.exitCode}',
      result.exitCode,
    );
  }
}
