part of 'store.dart';

enum UserActionType { external, auth, callback, conferencing, file, thread, plan }

enum ConferencingProvider { googleMeet, zoom, microsoftTeams, webex, other }

abstract class UserAction extends Equatable {
  const UserAction({required this.type});

  final UserActionType type;

  factory UserAction.fromJson(Map<String, dynamic> json) {
    final type = UserActionType.values.firstWhere(
      (t) => t.name == json['type'],
      orElse: () => UserActionType.external,
    );

    switch (type) {
      case UserActionType.external:
        return ExternalUserAction.fromJson(json);
      case UserActionType.auth:
        return AuthUserAction.fromJson(json);
      case UserActionType.callback:
        return CallbackUserAction.fromJson(json);
      case UserActionType.conferencing:
        return ConferencingUserAction.fromJson(json);
      case UserActionType.file:
        return FileUserAction.fromJson(json);
      case UserActionType.thread:
        return ThreadUserAction.fromJson(json);
      case UserActionType.plan:
        return PlanUserAction.fromJson(json);
    }
  }

  Map<String, dynamic> toJson();
}

class ExternalUserAction extends UserAction {
  const ExternalUserAction({required this.title, required this.url})
    : super(type: UserActionType.external);

  final String title;
  final String url;

  factory ExternalUserAction.fromJson(Map<String, dynamic> json) {
    return ExternalUserAction(
      title: json['title'] as String,
      url: json['url'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {'type': type.name, 'title': title, 'url': url};
  }

  @override
  List<Object?> get props => [type, title, url];
}

class AuthUserAction extends UserAction {
  const AuthUserAction({
    required this.title,
    required this.provider,
    required this.scopes,
    required this.callback,
  }) : super(type: UserActionType.auth);

  final String title;
  final AuthProvider provider;
  final List<String> scopes;
  final String callback;

  factory AuthUserAction.fromJson(Map<String, dynamic> json) {
    return AuthUserAction(
      title: json['title'] as String,
      provider: AuthProvider.values.firstWhere(
        (v) => v.name == json['provider'],
        orElse: () => AuthProvider.other,
      ),
      scopes: (json['scopes'] as List).cast<String>(),
      callback: json['callback'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'title': title,
      'provider': provider.name,
      'scopes': scopes,
      'callback': callback,
    };
  }

  @override
  List<Object?> get props => [type, title, provider, scopes, callback];
}

class CallbackUserAction extends UserAction {
  const CallbackUserAction({required this.title, required this.callback})
    : super(type: UserActionType.callback);

  final String title;
  final String callback;

  factory CallbackUserAction.fromJson(Map<String, dynamic> json) {
    return CallbackUserAction(
      title: json['title'] as String,
      callback: json['callback'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {'type': type.name, 'title': title, 'callback': callback};
  }

  @override
  List<Object?> get props => [type, title, callback];
}

class ConferencingUserAction extends UserAction {
  const ConferencingUserAction({required this.url, required this.provider})
    : super(type: UserActionType.conferencing);

  final String url;
  final ConferencingProvider provider;

  factory ConferencingUserAction.fromJson(Map<String, dynamic> json) {
    return ConferencingUserAction(
      url: json['url'] as String,
      provider: ConferencingProvider.values.firstWhere(
        (v) => v.name == json['provider'],
        orElse: () => ConferencingProvider.other,
      ),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {'type': type.name, 'url': url, 'provider': provider.name};
  }

  @override
  List<Object?> get props => [type, url, provider];
}

class FileUserAction extends UserAction {
  const FileUserAction({
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    this.imageWidth,
    this.imageHeight,
  }) : super(type: UserActionType.file);

  final String fileId;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final int? imageWidth;
  final int? imageHeight;

  bool get isImage => mimeType.startsWith('image/');

  factory FileUserAction.fromJson(Map<String, dynamic> json) {
    return FileUserAction(
      fileId: json['fileId'] as String,
      fileName: json['fileName'] as String,
      fileSize: json['fileSize'] as int,
      mimeType: json['mimeType'] as String,
      imageWidth: json['imageWidth'] as int?,
      imageHeight: json['imageHeight'] as int?,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'fileId': fileId,
      'fileName': fileName,
      'fileSize': fileSize,
      'mimeType': mimeType,
      if (imageWidth != null) 'imageWidth': imageWidth,
      if (imageHeight != null) 'imageHeight': imageHeight,
    };
  }

  @override
  List<Object?> get props =>
      [type, fileId, fileName, fileSize, mimeType, imageWidth, imageHeight];
}

class ThreadUserAction extends UserAction {
  const ThreadUserAction({
    required this.threadId,
    this.title,
    this.priorityId,
  }) : super(type: UserActionType.thread);

  final String threadId;
  final String? title;
  final String? priorityId;

  factory ThreadUserAction.fromJson(Map<String, dynamic> json) {
    return ThreadUserAction(
      threadId: json['threadId'] as String,
      title: json['title'] as String?,
      priorityId: json['priorityId'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'threadId': threadId,
      if (title != null) 'title': title,
      if (priorityId != null) 'priorityId': priorityId,
    };
  }

  @override
  List<Object?> get props => [type, threadId, title, priorityId];
}

/// A single operation within a plan submitted for user approval.
class PlanOperation extends Equatable {
  const PlanOperation({required this.type, required this.data});

  final String type;
  final Map<String, dynamic> data;

  factory PlanOperation.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    return PlanOperation(type: type, data: json);
  }

  Map<String, dynamic> toJson() => data;

  /// Human-readable description of this operation.
  String get description {
    switch (type) {
      case 'createThread':
        final title = data['title'] as String? ?? 'Untitled';
        final priorityTitle = data['priorityTitle'] as String?;
        if (priorityTitle != null) return 'Create "$title" in $priorityTitle';
        return 'Create "$title"';
      case 'createNote':
        final threadTitle = data['threadTitle'] as String? ?? 'thread';
        return 'Add note to "$threadTitle"';
      case 'updateThread':
        final threadTitle = data['threadTitle'] as String? ?? 'thread';
        final changes = data['changes'] as Map<String, dynamic>? ?? {};
        final parts = <String>[];
        if (changes['title'] != null) parts.add('rename');
        if (changes['archived'] == true) parts.add('archive');
        if (changes['archived'] == false) parts.add('unarchive');
        if (changes['type'] != null) parts.add('change type');
        if (changes['priority'] != null) {
          final p = changes['priority'] as Map<String, dynamic>;
          parts.add('move to ${p['title'] ?? 'priority'}');
        }
        if (parts.isEmpty) return 'Update "$threadTitle"';
        return 'Update "$threadTitle": ${parts.join(', ')}';
      case 'updateLink':
        final linkTitle = data['linkTitle'] as String? ?? 'link';
        final changes = data['changes'] as Map<String, dynamic>? ?? {};
        final threadTitle = changes['threadTitle'] as String?;
        if (threadTitle != null) return 'Move "$linkTitle" to "$threadTitle"';
        return 'Update "$linkTitle"';
      case 'updatePriority':
        final priorityTitle = data['priorityTitle'] as String? ?? 'priority';
        final changes = data['changes'] as Map<String, dynamic>? ?? {};
        final parts = <String>[];
        if (changes['title'] != null) parts.add('rename');
        if (changes['archived'] == true) parts.add('archive');
        if (changes['archived'] == false) parts.add('unarchive');
        if (changes['parent'] != null) {
          final p = changes['parent'] as Map<String, dynamic>;
          parts.add('move to ${p['title'] ?? 'parent'}');
        }
        if (parts.isEmpty) return 'Update "$priorityTitle"';
        return 'Update "$priorityTitle": ${parts.join(', ')}';
      default:
        return type;
    }
  }

  @override
  List<Object?> get props => [type, data];
}

class PlanUserAction extends UserAction {
  const PlanUserAction({
    required this.title,
    required this.operations,
    required this.callback,
  }) : super(type: UserActionType.plan);

  final String title;
  final List<PlanOperation> operations;
  final String callback;

  factory PlanUserAction.fromJson(Map<String, dynamic> json) {
    return PlanUserAction(
      title: json['title'] as String,
      operations: (json['operations'] as List)
          .map((op) => PlanOperation.fromJson(op as Map<String, dynamic>))
          .toList(),
      callback: json['callback'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'title': title,
      'operations': operations.map((op) => op.toJson()).toList(),
      'callback': callback,
    };
  }

  @override
  List<Object?> get props => [type, title, operations, callback];
}

class UserActionsConverter extends TypeConverter<List<UserAction>?, String?>
    with JsonTypeConverter2<List<UserAction>?, String?, List<dynamic>?> {
  const UserActionsConverter();

  @override
  List<UserAction>? fromSql(String? fromDb) {
    if (fromDb == null || fromDb.isEmpty) {
      return null;
    }
    try {
      final dynamic jsonData = jsonDecode(fromDb);
      if (jsonData is List) {
        return jsonData
            .map((json) => UserAction.fromJson(json as Map<String, dynamic>))
            .toList();
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  @override
  String? toSql(List<UserAction>? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    return jsonEncode(value.map((action) => action.toJson()).toList());
  }

  @override
  List<UserAction>? fromJson(List<dynamic>? json) {
    if (json == null) {
      return null;
    }
    try {
      return json
          .map((item) => UserAction.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return null;
    }
  }

  @override
  List<dynamic>? toJson(List<UserAction>? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    return value.map((action) => action.toJson()).toList();
  }
}
