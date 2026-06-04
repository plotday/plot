import 'package:flutter_test/flutter_test.dart';
import 'package:plot/widget/recipient_picker_modal.dart';

void main() {
  const self = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  const alice = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  const bob = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  const groupX = 'dddddddd-dddd-dddd-dddd-dddddddddddd';

  group('RecipientPickerResult', () {
    test('all thread contacts checked → accessContacts is null', () {
      final r = RecipientPickerResult.fromSelection(
        threadContacts: const [self, alice, bob],
        threadGroups: const [groupX],
        selectedContacts: {self, alice, bob},
        selectedGroups: {groupX},
        addedContacts: const [],
        addedGroups: const [],
        self: self,
      );
      expect(r.accessContacts, isNull);
      expect(r.accessGroups, isNull);
    });

    test('subset of contacts → explicit list including self', () {
      final r = RecipientPickerResult.fromSelection(
        threadContacts: const [self, alice, bob],
        threadGroups: const [],
        selectedContacts: {self, alice},
        selectedGroups: {},
        addedContacts: const [],
        addedGroups: const [],
        self: self,
      );
      expect(r.accessContacts, containsAll([self, alice]));
      expect(r.accessContacts!.length, 2);
    });

    test('Just me (private) → accessContacts=[self], accessGroups=[]', () {
      final r = RecipientPickerResult.justMe(self: self);
      expect(r.accessContacts, equals([self]));
      expect(r.accessGroups, equals(<String>[]));
    });

    test('Reply to original → accessContacts=[self, originalAuthor], accessGroups=[]', () {
      final r = RecipientPickerResult.replyToOriginal(self: self, originalAuthor: alice);
      expect(r.accessContacts, containsAll([self, alice]));
      expect(r.accessContacts!.length, 2);
      expect(r.accessGroups, equals(<String>[]));
    });

    test('added contact is included in accessContacts AND threadContactsAdded', () {
      final r = RecipientPickerResult.fromSelection(
        threadContacts: const [self, alice],
        threadGroups: const [],
        selectedContacts: {self, alice, bob},
        selectedGroups: {},
        addedContacts: const [bob],
        addedGroups: const [],
        self: self,
      );
      expect(r.accessContacts, contains(bob));
      expect(r.threadContactsAdded, equals([bob]));
    });

    test('subset of groups → explicit list', () {
      final r = RecipientPickerResult.fromSelection(
        threadContacts: const [self],
        threadGroups: const [groupX, 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'],
        selectedContacts: {self},
        selectedGroups: {groupX},
        addedContacts: const [],
        addedGroups: const [],
        self: self,
      );
      expect(r.accessGroups, equals([groupX]));
    });
  });

  group('RecipientPickerResult.fromPickerSelection', () {
    test('unchanged full selection → thread default (nulls)', () {
      final r = RecipientPickerResult.fromPickerSelection(
        threadContacts: const [self, alice, bob],
        threadGroups: const [groupX],
        finalContacts: const [self, alice, bob],
        finalGroups: const [groupX],
        self: self,
      );
      expect(r.accessContacts, isNull);
      expect(r.accessGroups, isNull);
      expect(r.threadContactsAdded, isEmpty);
      expect(r.threadGroupsAdded, isEmpty);
    });

    test('unchecking a contact → explicit subset including self', () {
      final r = RecipientPickerResult.fromPickerSelection(
        threadContacts: const [self, alice, bob],
        threadGroups: const [],
        finalContacts: const [self, alice], // bob unchecked
        finalGroups: const [],
        self: self,
      );
      expect(r.accessContacts, containsAll([self, alice]));
      expect(r.accessContacts!.length, 2);
      expect(r.threadContactsAdded, isEmpty);
    });

    test('picking someone not on the thread → added to thread + subset', () {
      final r = RecipientPickerResult.fromPickerSelection(
        threadContacts: const [self, alice],
        threadGroups: const [],
        finalContacts: const [self, alice, bob], // bob is new
        finalGroups: const [],
        self: self,
      );
      expect(r.threadContactsAdded, equals([bob]));
      expect(r.accessContacts, contains(bob));
    });

    test('new group is reported in threadGroupsAdded', () {
      final r = RecipientPickerResult.fromPickerSelection(
        threadContacts: const [self],
        threadGroups: const [],
        finalContacts: const [self],
        finalGroups: const [groupX], // new group
        self: self,
      );
      expect(r.threadGroupsAdded, equals([groupX]));
      expect(r.accessGroups, equals([groupX]));
    });
  });
}
