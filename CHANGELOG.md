## Unreleased

- New sub-minute frequencies: `everySecond()`, `everyTwoSeconds()`, `everyFiveSeconds()`, `everyTenSeconds()`, `everyFifteenSeconds()`, `everyTwentySeconds()` and `everyThirtySeconds()`. Like Laravel, the task repeats inside each due minute. The cron, days, `between()`, `when()`/`skip()` and `timezone()` still decide if the minute is due. `when()` and `skip()` are checked again before each repeat. `withoutOverlapping()` and `onOneServer()` work for each repeat. A slow run skips the steps it missed. `work` and `run` both repeat the task until the minute ends, so `run` from cron can take up to a minute. Without a sub-minute task, nothing changes: `work` still wakes once a minute and `run` ends at once. New `Scheduler.runRepeats(minute)` and `ScheduledTask.repeatSeconds`. `list` shows `every 5s`.

- New `clear-cache` command: `dart run bin/schedule.dart clear-cache` (or `dox schedule:clear-cache`). A crash left the `withoutOverlapping()` lock in the store, so the task was skipped for up to 24 hours. The command removes the overlap lock of each task in the schedule, by its exact key. Other cache keys stay. It prints one line per removed lock, or `No overlap locks found. Nothing to clear.` Do not run it while a task really runs on another process: that task could then start twice. `Scheduler.clearOverlapLocks()` does the same in code.
- Fix: `schedule list` did not show `between()`, `unlessBetween()` and `environments()`. So a task looked like it ran all day in every environment. Now the schedule column shows them, like `0 * * * *, between 09:00-17:00, env production`. The new `ScheduledTask.describeFilters()` gives this text.

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
