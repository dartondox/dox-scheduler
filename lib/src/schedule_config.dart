/// Settings of the scheduler. Keep one in `lib/config/schedule.dart`.
///
/// ```
/// ScheduleConfig scheduleConfig = ScheduleConfig(store: 'redis');
/// ```
class ScheduleConfig {
  const ScheduleConfig({this.inProcess = false, this.store});

  /// Run the schedule inside the running Dox app (`SchedulerProvider`).
  /// Off by default: run `dart run bin/schedule.dart work` instead.
  final bool inProcess;

  /// The cache store for the locks (a store name of `AppConfig.cache`).
  /// Null: the default store. A store without locks (null) falls back to
  /// memory. Memory and file locks work inside one server only; use a
  /// Redis store when many servers run the schedule. The scheduler prints
  /// a warning at start when the store is not shared.
  final String? store;
}
