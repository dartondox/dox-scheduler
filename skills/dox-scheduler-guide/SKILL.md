---
name: dox-scheduler-guide
description: Use when you add or change a scheduled task, set a cron or time frequency, run the scheduler (work, run, list, test), or avoid double runs across servers in a Dox (Dart) app.
---

# Dox scheduler

`dox_scheduler` runs Dart functions (or processes) on a cron-like schedule.
You write all tasks in one file. A task runs once per tick, even when many isolates or servers run the schedule.
For routes, controllers and the app layout, see the `dox-core-guide` skill.

## Setup

```bash
dart pub add dox_scheduler
```

A Dox app made by `dox create` already has these files:

- `lib/config/schedule.dart`: the `scheduleConfig` and the `schedule` function.
- `bin/schedule.dart`: the entry point of the scheduler process.
- `lib/providers/schedule_provider.dart`: runs the schedule inside the server (only when `inProcess` is true).

`lib/config/schedule.dart`:

```dart
import 'package:dox_scheduler/dox_scheduler.dart';

ScheduleConfig scheduleConfig = const ScheduleConfig();

void schedule(Schedule s) {
  s.call('cleanup', cleanup).dailyAt('02:00');
  s.call('report', () => SendReport().dispatch()).hourly();
}

Future<void> cleanup() async {
  // delete old rows, files, ...
}
```

`bin/schedule.dart`:

```dart
import 'dart:io';

import 'package:my_app/config/app.dart';
import 'package:my_app/config/schedule.dart';
import 'package:dox_scheduler/dox_scheduler.dart';

Future<void> main(List<String> args) async {
  exitCode = await SchedulerRunner(
    schedule: schedule,
    app: appConfig,
    config: scheduleConfig,
  ).run(args);
}
```

With `app: appConfig`, the runner starts your providers (like the database) first and stops them at the end.

`ScheduleConfig` fields:

| Field | Meaning |
| --- | --- |
| `inProcess` | Run the schedule inside the server. Default `false`. |
| `store` | Name of the cache store for the locks. `null` uses the default store. |
| `timezone` | Default zone for all tasks, like `'Asia/Yangon'`. `null` means UTC. |

## Recipes

### 1. Add a task

```dart
void schedule(Schedule s) {
  s.call('cleanup', cleanup).dailyAt('02:00');
  s.call('ping', ping).cron('*/5 * * * *').timezone('Asia/Yangon');
}
```

- `s.call(name, function)` adds a task. The name must be unique.
- The function can be sync or `Future<void>`.
- A task with no frequency runs every minute.
- The time is UTC unless you call `timezone()` or set `ScheduleConfig(timezone: ...)`.

### 2. Pick a frequency

Common methods: `everyMinute()`, `everyFiveMinutes()`, `everyFifteenMinutes()`, `hourly()`, `hourlyAt(17)`,
`daily()`, `dailyAt('13:00')`, `twiceDaily(1, 13)`, `weekly()`, `weeklyOn(DateTime.monday, '08:00')`,
`monthly()`, `monthlyOn(15, '12:00')`, `lastDayOfMonth('15:00')`, `quarterly()`, `yearly()`,
`everyFiveSeconds()` (and other second steps), and `cron('*/5 9-17 * * 1-5')`.

Limit the days: `weekdays()`, `weekends()`, `mondays()` ... `sundays()`, `days(<int>[DateTime.monday])`.

```dart
s.call('standup', remind).weekdays().dailyAt('09:00');
```

`cron()` takes 5 fields: `minute hour day-of-month month day-of-week`.
When both day fields are set, a day matches when either one matches. This is the standard cron rule.

### 3. Run a queue job

The scheduler does not know about queues. Wrap the dispatch in a function:

```dart
s.call('report', () => SendReport().dispatch()).hourly();
```

The task only puts the job on the queue. A queue worker runs it (see the `dox-queue-guide` skill).
The scheduler process (`bin/schedule.dart`) does not start a queue worker, also with `QueueConfig(workInProcess: true)`. Run `bin/queue.dart`, or `workInProcess` in the web server.

### 4. Run a process or a dox command

```dart
s.exec('pg_dump', args: <String>['-f', 'backup.sql', 'mydb']).daily();
s.command('queue:prune-failed', args: <String>['--hours=48']).hourly();
```

- `exec` uses no shell. `|`, `>` and `*` are plain text. Use `s.exec('sh', args: <String>['-c', '...'])` for a shell.
- A non-zero exit code fails the task.
- `command` runs `dox <name> <args>`. If `dox` is not on PATH, set `Schedule.doxExecutable = '/usr/local/bin/dox';`.
- The task name is the command line. Do not put a secret in `args` unless you pass your own `name:`.
- Keep the output with `sendOutputTo('storage/logs/x.log')`, `appendOutputTo(path)` or `onOutput((String output) {...})`.

### 5. Filter when a task runs

```dart
s.call('sync', sync).everyFiveMinutes().between('09:00', '17:00');
s.call('quiet', quiet).hourly().unlessBetween('23:00', '04:00');
s.call('emails', sendEmails).daily().environments(<String>['production']);
s.call('promo', promo).daily().when(isPromoOn);
s.call('backup', backup).daily().skip(isHoliday);
```

`when` and `skip` take a function that gives `bool` or `Future<bool>`.
`environments` compares with `APP_ENV` at run time.

### 6. Avoid overlap, set a timeout

```dart
s.call('import', importData)
    .everyFiveMinutes()
    .withoutOverlapping()
    .timeout(const Duration(minutes: 4));
```

- `withoutOverlapping([Duration])` holds a lock while the task runs. The lock expires after 24 hours by default.
- Dart can not stop a running function. After `timeout`, the run counts as failed, but the work may go on.
  Only the process of an `exec` or `command` task is killed.
- After a crash the lock may stay. Run `dart run bin/schedule.dart clear-cache`.

### 7. Hooks and pings

```dart
s.call('report', sendReport)
    .daily()
    .before(logStart)
    .onSuccess(logDone)
    .onFailure(alertTeam)
    .after(cleanUp)
    .pingOnFailure('https://health.example.com/report/fail');

Future<void> alertTeam(Object error, StackTrace stack) async {
  // notify the team
}
```

- `before` that throws stops the task and counts as failed.
- Ping methods: `pingBefore`, `thenPing`, `pingOnSuccess`, `pingOnFailure`. Each has an `If` form, like `pingOnFailureIf(bool, url)`.
- A failed ping is logged. It never fails the task.
- An error in one task is logged. The next task still runs.

### 8. Run the schedule

| Command | What it does |
| --- | --- |
| `dart run bin/schedule.dart work` | Long running. Runs due tasks every minute. This is the default. |
| `dart run bin/schedule.dart run` | Runs the tasks due this minute once, then exits. For a system cron. |
| `dart run bin/schedule.dart list` | Shows each task, its schedule and its next run time. |
| `dart run bin/schedule.dart test cleanup` | Runs the task `cleanup` now, with hooks. It skips filters and locks. |
| `dart run bin/schedule.dart clear-cache` | Removes the `withoutOverlapping` locks. |

The `dox` CLI has the same: `dox schedule:work` and `dox schedule:list`.

System cron line for `run`:

```bash
* * * * * cd /path/to/app && dart run bin/schedule.dart run
```

In production, compile it: `dart compile exe bin/schedule.dart -o build/schedule`.

### 9. Run inside the server

Set `ScheduleConfig(inProcess: true)`. The `ScheduleProvider` of the app then starts the loop.

```dart
class ScheduleProvider extends SchedulerProvider {
  ScheduleProvider() : super(schedule: schedule, config: scheduleConfig);
}
```

Only isolate 1 runs the tasks. With `inProcess` false, this provider does nothing.

## Gotchas

- Tasks run once per tick by default (`onOneServer()` is on). Use `onEveryServer()` to run on every process.
- The once-per-tick lock uses a cache store. A `memory` store is one process. A `file` store is one machine.
  With many servers, set a Redis store: `ScheduleConfig(store: 'redis')`.
  There is no database store.
- The scheduler prints a warning to stderr at start when a task uses `onOneServer()` and the store is `memory`, `file` or `null`.
  It is silent when `APP_ENV` is `development` or `local`.
- The default zone is UTC. Set `timezone` when you mean local time. An unknown zone name throws `ArgumentError` at start.
- With summer time: a skipped local time does not run that day. A repeated local time runs once.
- `yearlyOn(2, 30)` (a day the month never has) throws. A blank name in `environments` throws.
- A ping url that is not `http` or `https` throws `ArgumentError` when the schedule is made.
- `s.call` names must be unique. Pass `name:` to `exec` or `command` to add the same command line twice.
- `work` on Ctrl+C or SIGTERM waits for running tasks. A second signal stops at once.
- Do not run the schedule with `dart run` in production. Run the compiled binary.
