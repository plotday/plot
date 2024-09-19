import 'model.dart';
import 'package:plot/util/api.dart' as api;
import 'package:plot/store/store.dart' as store;

class Calendar extends RemoteModel<int>
    with store.CalendarStorable, store.CalendarSaveable {
  final String name;
  final bool enabled;
  final int accountId;

  Future<void> sync() async {
    await api.post(
      "/sync",
      body: {
        'calendarId': id,
      },
    );
  }

  /* Internal */

  const Calendar._({
    required this.name,
    required this.enabled,
    required this.accountId,
    required super.id,
    required super.createdAt,
    required super.modifiedAt,
  });

  factory Calendar.fromStore(store.Calendar row) => Calendar._(
        id: row.id,
        createdAt: row.createdAt,
        modifiedAt: row.modifiedAt,
        name: row.name,
        enabled: row.enabled,
        accountId: row.accountId,
      );

  @override
  List<Object?> get props => super.props + [name, enabled];

  @override
  store.Insertable<store.Calendar> toStore() => store.CalendarsCompanion.custom(
        id: store.Constant(id),
        modifiedAt: store.currentDateAndTime,
        name: store.Constant(name),
        enabled: store.Constant(enabled),
        accountId: store.Constant(accountId),
      );
}
