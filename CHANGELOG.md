## Unreleased

- Print one warning to stderr at start when a task uses `onOneServer()` but the lock store (memory, file or null) is not shared between servers. New optional `err` sink on `Scheduler`. No behaviour change.
- With `timeout()` and `withoutOverlapping()` in `work`, the overlap lock now stays until the work really ends, or until the lock expires. Before, the lock was freed at the timeout while the work went on, so a second run could start. When the command ends (`run`, or `work` after a stop), the lock is still freed, even if the work goes on. This is the same as 3.0.0. New `Scheduler.close()` frees these locks; `work()` and `SchedulerRunner` call it.
- `SchedulerRunner`: when a provider's `setup()` throws, the providers that already started are shut down in reverse order, then the setup error is thrown again.

## 3.0.0

- The first stable release.

## 3.0.0-alpha.2

- `SchedulerProvider` (was a DoxService): extend it in your app, `shutdown()` is optional.

## 3.0.0-alpha.1

- First version.
- Define tasks in Dart: `s.call('name', function)` with frequencies (`everyMinute` to `yearly`), `cron()` expressions, `weekdays`, `weekends`, `days`.
- Time zones with `timezone('Asia/Yangon')`. UTC by default. Summer time safe.
- Filters: `between`, `when`, `skip`.
- Options: `withoutOverlapping`, `onOneServer` (on by default), `onEveryServer`, `runInBackground`, `timeout`.
- Hooks: `before`, `after`, `onSuccess`, `onFailure`.
- `SchedulerRunner` for `bin/schedule.dart`: `work`, `run`, `list`, `test <name>`.
- `SchedulerService` runs the schedule inside the Dox server.
