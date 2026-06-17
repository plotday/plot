import 'package:flutter_test/flutter_test.dart';
import 'package:plot/cli_args.dart';
import 'package:plot/screenshot/scenes.dart';

void main() {
  test('parses --scene=<id>', () {
    CliArgs.resetForTest();
    CliArgs.init(['--scene=S1']);
    expect(CliArgs.scene, 'S1');
  });

  test('scene is null when absent', () {
    CliArgs.resetForTest();
    CliArgs.init(['--user=a@b.c']);
    expect(CliArgs.scene, isNull);
  });

  test('draftFor returns text only for the active scene target thread', () {
    Scenes.activate('S2', draftThreadTitle: 'Chelsea (A) — coaching staff plan',
        draftContent: 'Great work, all.');
    expect(Scenes.draftContentFor('Chelsea (A) — coaching staff plan'),
        'Great work, all.');
    expect(Scenes.draftContentFor('Some other thread'), isNull);
    Scenes.clear();
    expect(Scenes.draftContentFor('Chelsea (A) — coaching staff plan'), isNull);
  });

  test('parses --emulate-windows', () {
    CliArgs.resetForTest();
    CliArgs.init(['--emulate-windows']);
    expect(CliArgs.emulateWindows, isTrue);
  });

  test('emulateWindows defaults to false', () {
    CliArgs.resetForTest();
    CliArgs.init(['--scene=S1']);
    expect(CliArgs.emulateWindows, isFalse);
  });
}
