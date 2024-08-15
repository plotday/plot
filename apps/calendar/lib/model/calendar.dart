import 'model.dart';
import 'package:plot/util/api.dart' as api;

typedef CalendarID = int;

class Calendar extends RemoteModel<CalendarID> {
  static final store = Store<int, Calendar>();

  Calendar.fromJson(Map<String, dynamic> json)
      : name = json['name'] as String,
        enabled = json['enabled'] as bool,
        super(id: json['id'] as int);

  @override
  Map<String, dynamic> toJson() => {
        'name': name,
        'enabled': enabled,
      };

  @override
  Future<Calendar> save() async {
    final model = await saveToBase("calendar", Calendar.fromJson);
    store.put(model.id!, model);
    return model;
  }

  Future<void> sync() async {
    await api.post(
      "/sync",
      body: {
        'calendarId': id,
      },
    );
  }

  final String name;
  final bool enabled;

  @override
  List<Object?> get props => [id, name, enabled];
}
