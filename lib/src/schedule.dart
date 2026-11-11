import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
  /// `exec('sh', args: ['-c', '...'])` when you need a shell. A non-zero
  /// exit code fails the task. With `timeout()` the process is killed
  /// when the time is up. A stop of `work` waits for the process.
  ///
  /// The task [name] is the command line by default, like
  /// `php artisan inspire`. It shows in the logs, the lock keys and
  /// `list`. Give your own [name] when [args] hold a secret (like
  /// `--token=...`), or to add the same command line twice.
  ScheduledTask exec(
    String executable, {
    List<String> args = const <String>[],
    String? name,
  }) {
    List<String> argList = List<String>.of(args);
    late ScheduledTask task;
    task = call(
      name ?? <String>[executable, ...argList].join(' '),
      () => _runProcess(task, executable, argList),
    );
    return task;
  }

  /// Add a task that runs a `dox` command of the app, like
  /// `command('queue:prune', args: ['--hours=48'])`. It runs the process
  /// `dox queue:prune --hours=48` in the current folder (see
  /// [doxExecutable]). It works like `exec()`: the default [name] is
  /// that command line, so do not put a secret in [args] without a
  /// [name].
  ScheduledTask command(
    String command, {
    List<String> args = const <String>[],
    String? name,
  }) {
    return exec(doxExecutable, args: <String>[command, ...args], name: name);
  }

  /// The task named [name], or null.
  ScheduledTask? find(String name) {
    for (ScheduledTask task in _tasks) {
      if (task.name == name) return task;
    }
    return null;
  }
}

/// Run the process of [task]. Its output (stdout and stderr, as they
/// come) goes to the output file as it comes. It is held in memory only
/// when the task has `onOutput()` hooks. `timeout()` kills the process.
/// A non-zero exit code, or a failed file write, throws after the hooks.
Future<void> _runProcess(
  ScheduledTask task,
  String executable,
  List<String> args,
) async {
  Process process = await Process.start(executable, args);
  Duration? limit = task.timeoutAfter;
  Timer? killer = limit == null ? null : Timer(limit, process.kill);
  BytesBuilder? text = task.outputHooks.isEmpty ? null : BytesBuilder();
  RandomAccessFile? file;
  Object? fileError;
  String? path = task.outputPath;
  if (path != null) {
    try {
      FileMode mode = task.appendOutput ? FileMode.append : FileMode.write;
      file = await File(path).open(mode: mode);
    } catch (error) {
      fileError = error;
    }
  }
  // one chain, so the writes keep their order
  Future<void> writes = Future<void>.value();
  void onChunk(List<int> chunk) {
    text?.add(chunk);
    RandomAccessFile? out = file;
    if (out == null) return;
    writes = writes.then((_) async {
      if (fileError != null) return;
      try {
        await out.writeFrom(chunk);
      } catch (error) {
        fileError = error;
      }
    });
  }

  await Future.wait(<Future<void>>[
    process.stdout.forEach(onChunk),
    process.stderr.forEach(onChunk),
  ]);
  int code = await process.exitCode;
  killer?.cancel();
  await writes;
  try {
    await file?.close();
  } catch (error) {
    fileError ??= error;
  }
  if (text != null) {
    String output = systemEncoding.decode(text.takeBytes());
    for (TaskOutputHook hook in task.outputHooks) {
      await hook(output);
    }
  }
  if (code != 0) {
    throw ProcessException(executable, args, 'Exit code $code', code);
  }
  if (fileError case Object error) throw error;
}
