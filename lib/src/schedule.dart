import 'scheduled_task.dart';

/// The list of tasks. Your `schedule()` function fills it:
/// ```
/// void schedule(Schedule s) {
///   s.call('cleanup', cleanup).dailyAt('02:00');
///   s.call('report', sendReport).hourly();
/// }
/// ```
class Schedule {
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
    _tasks.add(task);
    return task;
  }

  /// The task named [name], or null.
  ScheduledTask? find(String name) {
    for (ScheduledTask task in _tasks) {
      if (task.name == name) return task;
    }
    return null;
  }
}
