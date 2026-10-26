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
  /// Null: the default store. A store without locks (file, null) falls
  /// back to memory. Memory locks work inside one process only; use a
  /// Redis store when many servers run the schedule.
  final String? store;
}
