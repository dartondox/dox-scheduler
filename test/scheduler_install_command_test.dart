import 'dart:io';

import 'package:dox_annotation/install.dart';
import 'package:dox_scheduler/commands.dart';
import 'package:test/test.dart';

/// records the `dart` commands, runs nothing
class FakeRunner extends ProcessRunner {
  final List<String> calls = <String>[];

  @override
  Future<int> run(String executable, List<String> args, String folder) async {
    calls.add(args.join(' '));
    return 0;
  }
}

void main() {
  late Directory root;
  late FakeRunner runner;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dox_scheduler_install_');
    File('${root.path}/pubspec.yaml').writeAsStringSync(
      'name: my_app\n\ndependencies:\n  dox_scheduler: ^3.1.0\n',
    );
    File('${root.path}/.env').writeAsStringSync('APP_KEY=x\n');
    runner = FakeRunner();
    exitCode = 0;
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  String read(String path) => File('${root.path}/$path').readAsStringSync();

  Future<void> install(List<String> args) {
    return SchedulerInstallCommand(root: root, runner: runner).run(args);
  }

  /// every file of the app and its text
  Map<String, String> snapshot() {
    Map<String, String> files = <String, String>{};
    for (FileSystemEntity f in root.listSync(recursive: true)) {
      if (f is File) files[f.path] = f.readAsStringSync();
    }
    return files;
  }

  test('writes the config, the provider and the entry file', () async {
    await install(<String>[]);
    expect(exitCode, 0);
    expect(runner.calls, <String>['run build_runner build']);
    expect(read('lib/config/schedule.dart'), contains('void schedule('));
    expect(
      read('lib/providers/schedule_provider.dart'),
      allOf(
        contains("import 'package:my_app/config/schedule.dart';"),
        contains('ScheduleProvider extends SchedulerProvider'),
      ),
    );
    expect(read('bin/schedule.dart'), contains('SchedulerRunner'));
    expect(read('.env'), 'APP_KEY=x\n');
  });

  test('a second run changes nothing, even after an edit', () async {
    await install(<String>[]);
    File('${root.path}/lib/config/schedule.dart').writeAsStringSync('mine');
    Map<String, String> before = snapshot();
    await install(<String>[]);
    expect(snapshot(), before);
  });

  test('any option stops with exit code 1 and writes nothing', () async {
    for (List<String> args in <List<String>>[
      <String>['--driver=x'],
      <String>['now'],
      <String>['--'],
    ]) {
      Map<String, String> before = snapshot();
      await install(args);
      expect(exitCode, 1, reason: '$args');
      expect(runner.calls, isEmpty, reason: '$args');
      expect(snapshot(), before, reason: '$args');
      exitCode = 0;
    }
  });
}
