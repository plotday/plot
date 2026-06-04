import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/compose/connection_choice.dart';

void main() {
  group('PlotThreadChoice', () {
    test('plotDefault is the scope-less Plot choice', () {
      const choice = ConnectionChoice.plotDefault;
      expect(choice.key, 'plot');
      expect(choice.label, 'Plot');
      expect(choice.toUserAction(), isNull);
      // No team scope by default → no scope label.
      expect(choice.hasTeams, isFalse);
      expect(choice.scopeLabel, '');
    });

    test('searchText keeps the thread findable by note/chat terms', () {
      expect(ConnectionChoice.plotDefault.searchText, contains('plot'));
      expect(ConnectionChoice.plotDefault.searchText, contains('note'));
      expect(ConnectionChoice.plotDefault.searchText, contains('chat'));
    });

    group('scopeLabel', () {
      test('is empty when the user has no teams', () {
        expect(
          const PlotThreadChoice(hasTeams: false).scopeLabel,
          '',
        );
        // Even with a team id, no scope is surfaced when the user has no teams.
        expect(
          PlotThreadChoice(hasTeams: false, teamId: BigInt.from(7)).scopeLabel,
          '',
        );
      });

      test('is "Personal" when the user has teams but no team scope', () {
        expect(
          const PlotThreadChoice(hasTeams: true).scopeLabel,
          'Personal',
        );
      });

      test('is the team name when scoped to a team', () {
        expect(
          PlotThreadChoice(
            hasTeams: true,
            teamId: BigInt.from(7),
            teamName: 'Acme',
          ).scopeLabel,
          'Acme',
        );
      });

      test('falls back to "Team" when the name is unknown', () {
        expect(
          PlotThreadChoice(hasTeams: true, teamId: BigInt.from(7)).scopeLabel,
          'Team',
        );
      });
    });
  });
}
