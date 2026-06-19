import 'package:flutter_test/flutter_test.dart';

import 'package:plot/api/twist_api.dart';
import 'package:plot/widget/onboarding/onboarding_tools.dart';

Twist _twist({
  required String packageId,
  required String environment,
  String? category,
  String? name,
  bool isSource = true,
}) {
  return Twist(
    id: '$packageId-$environment',
    twistPackageId: packageId,
    name: name ?? packageId,
    tools: const [],
    environment: environment,
    isSource: isSource,
    category: category,
  );
}

void main() {
  group('onboardingConnectors', () {
    test('shows the public row, not a stale review row that shadows it', () {
      // Gmail's public row is correctly categorized, but its review row is
      // stale (null category) because it was deployed before the category
      // field existed. Reviewers receive both rows from /twists; onboarding
      // must surface the public one so Gmail lands in Messaging, not Apps.
      final selected = onboardingConnectors([
        _twist(packageId: 'gmail', environment: 'review', category: null),
        _twist(
          packageId: 'gmail',
          environment: 'public',
          category: 'messaging',
        ),
      ]);

      expect(selected, hasLength(1));
      expect(selected.single.environment, 'public');
      expect(selected.single.category, 'messaging');
    });

    test('excludes review-only and personal connectors', () {
      final selected = onboardingConnectors([
        _twist(
          packageId: 'review-only',
          environment: 'review',
          category: 'messaging',
        ),
        _twist(
          packageId: 'personal-only',
          environment: 'personal',
          category: 'calendar',
        ),
        _twist(
          packageId: 'public-one',
          environment: 'public',
          category: 'messaging',
        ),
      ]);

      expect(selected.map((t) => t.twistPackageId), ['public-one']);
    });

    test('excludes non-source twists', () {
      final selected = onboardingConnectors([
        _twist(packageId: 'a-twist', environment: 'public', isSource: false),
        _twist(packageId: 'a-source', environment: 'public', isSource: true),
      ]);

      expect(selected.map((t) => t.twistPackageId), ['a-source']);
    });

    test('returns one tile per package, sorted by name', () {
      final selected = onboardingConnectors([
        _twist(packageId: 'slack', environment: 'public', name: 'Slack'),
        _twist(packageId: 'gmail', environment: 'public', name: 'Gmail'),
      ]);

      expect(selected.map((t) => t.name), ['Gmail', 'Slack']);
    });
  });
}
