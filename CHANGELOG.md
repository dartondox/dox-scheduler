## Unreleased

- Ships an AI agent skill (dox-scheduler-guide). Install it in your app with `dart run skills@ get`.
- Requires Dart 3.14 or newer.
- New sub-minute frequencies: `everySecond()`, `everyTwoSeconds()`, `everyFiveSeconds()`, `everyTenSeconds()`, `everyFifteenSeconds()`, `everyTwentySeconds()` and `everyThirtySeconds()`. Like Laravel, the task repeats inside each due minute. The cron, days, `between()`, `when()`/`skip()` and `timezone()` still decide if the minute is due. `when()` and `skip()` are checked again before each repeat. `withoutOverlapping()` and `onOneServer()` work for each repeat. A slow run skips the steps it missed. `work` and `run` both repeat the task until the minute ends, so `run` from cron can take up to a minute. Without a sub-minute task, nothing changes: `work` still wakes once a minute and `run` ends at once. New `Scheduler.runRepeats(minute)` and `ScheduledTask.repeatSeconds`. `list` shows `every 5s`.
- New `schedule.exec(executable, args: [...], name: ...)`: a task that runs a process, without a shell. A non-zero exit code (or a missing program) fails the task. Use `exec('sh', args: ['-c', '...'])` when you need a shell. Its stdin is closed at start. With `timeout()`, the process gets SIGTERM when the time is up, and SIGKILL after `Schedule.processGrace` (5 seconds). Only the process itself is killed; the children of a shell may live on, and their output is dropped after the grace time. New `schedule.command(command, args: [...], name: ...)`: runs a `dox` command of the app as the process `dox <command> <args>`. Set `Schedule.doxExecutable` to a full path when `dox` is not on PATH. The task name is the command line, like `dox queue:prune --hours=48`, unless you give a `name`. Give a name when the args hold a secret: the name shows in the logs, the lock keys and `list`. The output is dropped unless you use the output hooks.
- New output hooks for `exec()` and `command()` tasks: `sendOutputTo(path)` replaces the file each run, `appendOutputTo(path)` adds to it, and `onOutput((String output) {...})` gets the text. The output is stdout and stderr, as it comes. The file gets it as it comes. `onOutput` holds the whole output in memory. The output is also written when the process fails. A file that can not be written fails the task, after the `onOutput` hooks got the output. A throwing `onOutput` hook fails the task. When more than one thing fails, the error is the first of: a non-zero exit code, an `onOutput` error, a file error. On a callback task these hooks do nothing.
- New ping hooks: `pingBefore(url)`, `thenPing(url)` (after the task, also when it failed), `pingOnSuccess(url)` and `pingOnFailure(url)`, plus `pingBeforeIf`, `thenPingIf`, `pingOnSuccessIf` and `pingOnFailureIf` that take a bool first. Each sends a GET request with `HttpClient`. A ping fails after `ScheduledTask.pingTimeout` (10 seconds), and its connection is then closed. A status of 400 or more counts as a failed ping. A failed ping is logged and never fails the task. A url that is not http or https throws an `ArgumentError` when the schedule is made. Replace `ScheduledTask.sendPing` in tests.
- New `clear-cache` command: `dart run bin/schedule.dart clear-cache` (or `dox schedule:clear-cache`). A crash left the `withoutOverlapping()` lock in the store, so the task was skipped for up to 24 hours. The command removes the overlap lock of each task in the schedule, by its exact key. Other cache keys stay. It prints one line per removed lock, or `No overlap locks found. Nothing to clear.` Do not run it while a task really runs on another process: that task could then start twice. `Scheduler.clearOverlapLocks()` does the same in code.
- Fix: `schedule work` kept a little memory each minute, about 0.4 MB a day. Each sleep left a listener on a stop signal that only ended at shutdown. Now each sleep has its own signal, so nothing stays behind.
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
