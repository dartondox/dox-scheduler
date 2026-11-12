## 3.1.1

- Fix: `schedule work` kept a little memory each minute, about 0.4 MB a day. Each sleep left a listener on a stop signal that only ended at shutdown. Now each sleep has its own signal, so nothing stays behind.

## 3.1.0

- Fix: `schedule work` now ends in a few seconds after Ctrl+C or SIGTERM, once the running tasks finish. Before, it waited for the next full minute (up to 60 seconds), so `docker stop` could kill it while tasks still ran. The sleep timer is now cancelled at the stop. A timer that a custom `ScheduleClock.sleep` starts is cancelled too, so do not start a timer for other work there.
- New `ScheduleConfig(timezone: 'Asia/Yangon')`: the default time zone of every task. `Schedule({String? timezone})` takes it too. A task's own `timezone()` still wins. Null (the default) is UTC, like before. An unknown name throws an `ArgumentError`.
- New `environments(['production'])` filter: the task runs only when `APP_ENV` is one of the names. Case and spaces do not matter. It is checked at run time, with `when()` and `skip()`. A blank name throws an `ArgumentError`, because it would match a missing `APP_ENV`.
- New frequencies: `everyThreeMinutes`, `everyFourMinutes`, `everyTwoHours`, `everyThreeHours`, `everyFourHours`, `everySixHours`, `everyOddHour`, `twiceDailyAt`, `at`, `lastDayOfMonth`, `twiceMonthly`, `quarterly`, `quarterlyOn`, `yearlyOn`, and `mondays()` to `sundays()`. `quarterlyOn` and `yearlyOn` check their values before they change the task. `yearlyOn` throws a `RangeError` for a day the month never has, like `yearlyOn(2, 30)`.
- New `unlessBetween(start, end)` filter: the opposite of `between()`. It works in `isDue`, `nextRun` and `list`.
- Fix: `dailyAt('13')` (an hour with no minutes) now means 13:00, like Laravel. Before, it threw a `FormatException`. The same works for `weeklyOn`, `monthlyOn` and `between`.
- Print one warning to stderr at start when a task uses `onOneServer()` but the lock store (memory, file or null) is not shared between servers. New optional `err` sink on `Scheduler`. No behaviour change. It does not print when `APP_ENV` is `development` or `local`, so a new app does not see it on every `schedule work` on a dev machine.
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
