import 'package:clerk_auth/clerk_auth.dart';
import 'package:clerk_auth/src/models/api/external_error.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/auth/auth_error_classifier.dart';

void main() {
  group('isNonRecoverableAuthError', () {
    test('returns false for unrelated codes', () {
      const e = ClerkError(
        code: ClerkErrorCode.unknownError,
        message: 'Something went wrong',
      );
      expect(isNonRecoverableAuthError(e), isFalse);
    });

    test('returns false for noSessionTokenRetrieved with no auth subcode '
        '(treated as transient — body unparseable, server outage, etc.)', () {
      const e = ClerkError(
        code: ClerkErrorCode.noSessionTokenRetrieved,
        message: 'No session token retrieved',
      );
      expect(isNonRecoverableAuthError(e), isFalse);
    });

    // Multi-error path: api.dart line 908 throws ExternalError(message: ..., errors: ...)
    // and Auth._catchExternalErrors wraps via ClerkError.from, which preserves the
    // collection on `errors`. _PlotClerkAuth.handleError can read sub-codes directly.
    test('returns true for multi-error collection containing '
        'authentication_invalid', () {
      final e = ClerkError.from(const ExternalErrorCollection(errors: [
        ExternalError(message: 'Other', code: 'something_else'),
        ExternalError(
          message: 'Invalid authentication',
          code: 'authentication_invalid',
        ),
      ]));
      expect(isNonRecoverableAuthError(e), isTrue);
    });

    test('returns true for multi-error collection containing signed_out', () {
      final e = ClerkError.from(const ExternalErrorCollection(errors: [
        ExternalError(message: 'Signed out', code: 'signed_out'),
      ]));
      expect(isNonRecoverableAuthError(e), isTrue);
    });

    test('returns false for multi-error collection with only generic errors',
        () {
      final e = ClerkError.from(const ExternalErrorCollection(errors: [
        ExternalError(message: 'Bad input', code: 'form_param_unknown'),
      ]));
      expect(isNonRecoverableAuthError(e), isFalse);
    });

    // Single-error path: api.dart line 906 throws errors.error (a leaf
    // ExternalError with no nested `errors` collection). Auth._catchExternalErrors
    // line 71 falls into the else branch and constructs:
    //   ClerkError(message: error.toString(), code: serverErrorResponse)
    // The leaf's `code` field is now ONLY visible as a substring inside `message`.
    // This is the production failure mode — the previous override missed it
    // because it relied on the `errors` collection that this path strips.
    test('returns true for single-error wrapped form (production bug case): '
        'serverErrorResponse with no collection but authentication_invalid '
        'in message', () {
      const leaf = ExternalError(
        message: 'Invalid authentication',
        code: 'authentication_invalid',
        longMessage:
            'Unable to authenticate the request, you need to supply an '
            'active session',
      );
      final wrapped = ClerkError(
        message: leaf.toString(),
        code: ClerkErrorCode.serverErrorResponse,
      );
      expect(isNonRecoverableAuthError(wrapped), isTrue);
    });

    test('returns true for single-error wrapped form: signed_out in message',
        () {
      const leaf = ExternalError(message: 'Signed out', code: 'signed_out');
      final wrapped = ClerkError(
        message: leaf.toString(),
        code: ClerkErrorCode.serverErrorResponse,
      );
      expect(isNonRecoverableAuthError(wrapped), isTrue);
    });

    test('returns true for single-error wrapped form: session_not_found', () {
      const leaf = ExternalError(
        message: 'Session not found',
        code: 'session_not_found',
      );
      final wrapped = ClerkError(
        message: leaf.toString(),
        code: ClerkErrorCode.serverErrorResponse,
      );
      expect(isNonRecoverableAuthError(wrapped), isTrue);
    });

    test('returns false for single-error wrapped form with non-auth code', () {
      const leaf = ExternalError(
        message: 'Form parameter incorrect',
        code: 'form_password_incorrect',
      );
      final wrapped = ClerkError(
        message: leaf.toString(),
        code: ClerkErrorCode.serverErrorResponse,
      );
      expect(isNonRecoverableAuthError(wrapped), isFalse);
    });

    // Defensive: the error code substring must appear in a `code: <value>`
    // shape produced by the JSON map toString — not just anywhere in free
    // text. This guards against false positives if a long_message happens
    // to mention "authentication_invalid" or similar verbatim.
    test('returns false when subcode appears only in prose, not as `code: '
        '<subcode>`', () {
      const e = ClerkError(
        code: ClerkErrorCode.unknownError,
        message:
            'Some unrelated long message that mentions authentication_invalid '
            'as a word but never as a structured code field',
      );
      expect(isNonRecoverableAuthError(e), isFalse);
    });
  });
}
