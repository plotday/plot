import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/command/unread_filter.dart';

void main() {
  group('ToggleUnreadFilter command', () {
    test('inactive form exposes the shortcut and envelope icons', () {
      final cmd = ToggleUnreadFilter(active: false);
      expect(cmd.title, 'Show unread only');
      expect(cmd.icon, FontAwesomeIcons.envelopeDot);
      expect(cmd.hoverIcon, FontAwesomeIcons.solidEnvelopeDot);
      expect(cmd.on, isFalse);
      expect(cmd.shortcut, isA<SingleActivator>());
      final s = cmd.shortcut as SingleActivator;
      expect(s.trigger, LogicalKeyboardKey.keyU);
      expect(s.shift, isTrue);
      // platformSingleActivator sets either meta or control, never both.
      expect(s.meta || s.control, isTrue);
    });

    test('active form flips title and on flag', () {
      final cmd = ToggleUnreadFilter(active: true);
      expect(cmd.title, 'Showing unread only');
      expect(cmd.on, isTrue);
    });
  });
}
