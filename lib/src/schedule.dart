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

  /// After `timeout()` sends SIGTERM to a process, it gets this long to
  /// end, then it gets SIGKILL. After a process ends, its output pipes
  /// get this long to close too. A child of a shell can keep them open;
  /// then the rest of the output is dropped. Default: 5 seconds.
  static Duration processGrace = const Duration(seconds: 5);

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
  /// exit code fails the task. Its stdin is closed at start, so a
  /// program that waits for input ends. With `timeout()` the process is
  /// killed when the time is up (SIGTERM, then SIGKILL after
  /// [processGrace]). Only the process itself is killed: the children of
  /// a shell may live on. A stop of `work` waits for the process.
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
/// Errors, first one wins: a non-zero exit code, an `onOutput()` hook,
/// the file write. They are thrown after the hooks ran.
Future<void> _runProcess(
  ScheduledTask task,
  String executable,
  List<String> args,
) async {
  Process process = await Process.start(executable, args);
  // a program that reads stdin must not wait forever
  process.stdin.close().ignore();
  Duration grace = Schedule.processGrace;
  Duration? limit = task.timeoutAfter;
  Timer? hardKill;
  Timer? killer = limit == null
      ? null
      : Timer(limit, () {
          process.kill();
          hardKill = Timer(grace, () => process.kill(ProcessSignal.sigkill));
        });
  BytesBuilder? text = task.outputHooks.isEmpty ? null : BytesBuilder();
  RandomAccessFile? file;
  Object? fileError;
  // one chain, so the writes keep their order
  Future<void> writes = Future<void>.value();
  List<StreamSubscription<List<int>>> pipes = <StreamSubscription<List<int>>>[];
  try {
    String? path = task.outputPath;
    if (path != null) {
      try {
        FileMode mode = task.appendOutput ? FileMode.append : FileMode.write;
        file = await File(path).open(mode: mode);
      } catch (error) {
        fileError = error;
      }
    }
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

    List<Future<void>> ended = <Future<void>>[];
    for (Stream<List<int>> stream in <Stream<List<int>>>[
      process.stdout,
      process.stderr,
    ]) {
      Completer<void> end = Completer<void>();
      pipes.add(
        stream.listen(
          onChunk,
          onDone: end.complete,
          onError: end.completeError,
          cancelOnError: true,
        ),
      );
      ended.add(end.future);
    }
    int code = await process.exitCode;
    killer?.cancel();
    hardKill?.cancel();
    try {
      await Future.wait(ended).timeout(grace);
    } on TimeoutException {
      // ponytail: a shell child still holds the pipes; drop the rest
    }
    await writes;
    Object? hookError;
    StackTrace? hookStack;
    if (text != null) {
      String output = systemEncoding.decode(text.takeBytes());
      for (TaskOutputHook hook in task.outputHooks) {
        try {
          await hook(output);
        } catch (error, stack) {
          hookError ??= error;
          hookStack ??= stack;
        }
      }
    }
    if (code != 0) {
      throw ProcessException(executable, args, 'Exit code $code', code);
    }
    if (hookError != null) Error.throwWithStackTrace(hookError, hookStack!);
  } finally {
    killer?.cancel();
    hardKill?.cancel();
    for (StreamSubscription<List<int>> pipe in pipes) {
      await pipe.cancel();
    }
    try {
      await writes;
      await file?.close();
    } catch (error) {
      fileError ??= error;
    }
  }
  if (fileError case Object error) throw error;
}
