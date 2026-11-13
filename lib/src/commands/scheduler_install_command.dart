import 'dart:io';

import 'package:dox_annotation/command.dart';
import 'package:dox_annotation/install.dart';

/// `dox scheduler:install`. `dox add scheduler` runs it. It sets up the
/// scheduler in an app: `lib/config/schedule.dart`, the provider and
/// `bin/schedule.dart`. It has no options and no `.env` keys.
/// It never overwrites a file, so it is safe to run twice.
class SchedulerInstallCommand extends Command {
  /// [root] is the app folder (the current folder by default). [runner]
  /// runs `dart`, tests pass a fake one.
  SchedulerInstallCommand({this.root, this.runner});

  final Directory? root;
  final ProcessRunner? runner;

  @override
  String get name => 'scheduler:install';

  @override
  String get description => 'Set up the task scheduler in this app';

  @override
  String get usage => 'scheduler:install';

  @override
  Future<void> run(List<String> args) async {
    if (args.isNotEmpty) {
      print('Unknown option. scheduler:install has no options.');
      exitCode = 1;
      return;
    }
    Installer installer = Installer(root: root, runner: runner);
    String app = installer.appName;

    installer.writeFile('lib/config/schedule.dart', scheduleConfig);
    installer.writeFile(
      'lib/providers/schedule_provider.dart',
      scheduleProvider(app),
    );
    installer.writeFile('bin/schedule.dart', scheduleEntry(app));

    await installer.buildRunner();
    installer.printSummary(<String>[
      'Add tasks in lib/config/schedule.dart.',
      'See them: `dart run bin/schedule.dart list`.',
      'Run them next to the server: `dart run bin/schedule.dart work`.',
    ]);
  }

  /// `lib/config/schedule.dart`, the same as the app template
  static const String scheduleConfig = '''
import 'package:dox_scheduler/dox_scheduler.dart';

/// Scheduler settings
/// -------------------------------
/// `store`: the cache store for the locks (config/cache.dart). Default:
/// the default store. Use a Redis store when many servers run the
/// schedule, so each task runs once per minute.
/// `inProcess`: run the schedule inside the server
/// (lib/providers/schedule_provider.dart). Off: run
/// `dart run bin/schedule.dart work` next to the server.
ScheduleConfig scheduleConfig = const ScheduleConfig();

/// Scheduled tasks
/// -------------------------------
/// Add a task with `s.call(name, function)` and a frequency.
/// `dart run bin/schedule.dart list` shows them and their next run time.
/// The times are UTC unless you call `timezone('Asia/Yangon')`.
void schedule(Schedule s) {
  // s.call('cleanup', cleanup).dailyAt('02:00');
  // s.call('report', () => SendReport().dispatch()).hourly();
}
''';

  /// `lib/providers/schedule_provider.dart`, the same as the app template
  static String scheduleProvider(String app) {
    return '''
import 'package:$app/config/schedule.dart';
import 'package:dox_scheduler/dox_scheduler.dart';

/// Scheduler provider
/// --------------------------
/// Runs the schedule inside the server when `scheduleConfig.inProcess`
/// is true (lib/config/schedule.dart). Only the first isolate runs it.
/// When it is off, this provider does nothing.
class ScheduleProvider extends SchedulerProvider {
  ScheduleProvider() : super(schedule: schedule, config: scheduleConfig);
}
''';
  }

  /// `bin/schedule.dart`, the same as the app template
  static String scheduleEntry(String app) {
    return '''
import 'dart:io';

import 'package:$app/config/app.dart';
import 'package:$app/config/schedule.dart';
import 'package:dox_scheduler/dox_scheduler.dart';

/// run the scheduled tasks of lib/config/schedule.dart:
/// `dart run bin/schedule.dart <work|run|list|test <name>>`, default work.
/// - work: run due tasks at every minute, until Ctrl+C or SIGTERM.
/// - run: run the tasks due this minute once (for a system cron).
/// - list: show each task, its schedule and next run time.
/// - test cleanup: run the task named cleanup now.
/// the app providers (like the database) start first.
Future<void> main(List<String> args) async {
  exitCode = await SchedulerRunner(
    schedule: schedule,
    app: appConfig,
    config: scheduleConfig,
  ).run(args);
}
''';
  }
}
