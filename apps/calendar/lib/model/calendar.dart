import 'model.dart';

class Calendar extends Model {
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

  final String name;
  final bool enabled;

  @override
  List<Object?> get props => [id, name, enabled];
}
