import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/compose/connection_choice.dart';

void main() {
  group('PlotThreadChoice variants', () {
    test('plotNote has key, label, and null user-action', () {
      expect(ConnectionChoice.plotNote.kind, PlotThreadKind.note);
      expect(ConnectionChoice.plotNote.key, 'plot:note');
      expect(ConnectionChoice.plotNote.label, 'Plot note');
      expect(ConnectionChoice.plotNote.toUserAction(), isNull);
    });

    test('plotTask has key, label, and null user-action', () {
      expect(ConnectionChoice.plotTask.kind, PlotThreadKind.task);
      expect(ConnectionChoice.plotTask.key, 'plot:task');
      expect(ConnectionChoice.plotTask.label, 'Plot task');
      expect(ConnectionChoice.plotTask.toUserAction(), isNull);
    });

    test('plotChat has key, label, and null user-action', () {
      expect(ConnectionChoice.plotChat.kind, PlotThreadKind.chat);
      expect(ConnectionChoice.plotChat.key, 'plot:chat');
      expect(ConnectionChoice.plotChat.label, 'Plot chat');
      expect(ConnectionChoice.plotChat.toUserAction(), isNull);
    });

    test('plotDefault maps to plotNote', () {
      expect(ConnectionChoice.plotDefault, same(ConnectionChoice.plotNote));
    });

    test('plotForKind returns the correct variant', () {
      expect(
        ConnectionChoice.plotForKind(PlotThreadKind.note),
        same(ConnectionChoice.plotNote),
      );
      expect(
        ConnectionChoice.plotForKind(PlotThreadKind.task),
        same(ConnectionChoice.plotTask),
      );
      expect(
        ConnectionChoice.plotForKind(PlotThreadKind.chat),
        same(ConnectionChoice.plotChat),
      );
    });

    test('searchText is lowercase of label', () {
      expect(ConnectionChoice.plotNote.searchText, 'plot note');
      expect(ConnectionChoice.plotTask.searchText, 'plot task');
      expect(ConnectionChoice.plotChat.searchText, 'plot chat');
    });
  });
}
