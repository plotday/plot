import 'package:flutter_test/flutter_test.dart';
import 'package:plot/api/api_exception.dart';

void main() {
  test('isAddonRequired is true only for plan_limit_exceeded + addon_required', () {
    expect(
      ApiException(
        statusCode: 403,
        endpoint: '/test',
        title: 'Access Denied',
        description: 'msg',
        code: 'plan_limit_exceeded',
        reason: 'addon_required',
      ).isAddonRequired,
      isTrue,
    );
    expect(
      ApiException(
        statusCode: 403,
        endpoint: '/test',
        title: 'Access Denied',
        description: 'msg',
        code: 'plan_limit_exceeded',
        reason: 'connection_limit',
      ).isAddonRequired,
      isFalse,
    );
    expect(
      ApiException(
        statusCode: 403,
        endpoint: '/test',
        title: 'Access Denied',
        description: 'msg',
        code: 'plan_limit_exceeded',
      ).isAddonRequired,
      isFalse,
    );
  });

  test('isTwistAddonRequired is true only for plan_limit_exceeded + twist_addon_required', () {
    expect(
      ApiException(
        statusCode: 403,
        endpoint: '/test',
        title: 'Access Denied',
        description: 'msg',
        code: 'plan_limit_exceeded',
        reason: 'twist_addon_required',
        candidateWeight: 20,
      ).isTwistAddonRequired,
      isTrue,
    );
    expect(
      ApiException(
        statusCode: 403,
        endpoint: '/test',
        title: 'Access Denied',
        description: 'msg',
        code: 'plan_limit_exceeded',
        reason: 'twist_addon_required',
        candidateWeight: 20,
      ).candidateWeight,
      equals(20),
    );
    expect(
      ApiException(
        statusCode: 403,
        endpoint: '/test',
        title: 'Access Denied',
        description: 'msg',
        code: 'plan_limit_exceeded',
        reason: 'addon_required',
      ).isTwistAddonRequired,
      isFalse,
    );
    expect(
      ApiException(
        statusCode: 403,
        endpoint: '/test',
        title: 'Access Denied',
        description: 'msg',
        code: 'plan_limit_exceeded',
      ).isTwistAddonRequired,
      isFalse,
    );
  });
}
