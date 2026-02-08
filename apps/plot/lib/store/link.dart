part of 'store.dart';

enum LinkType { external, auth, callback, conferencing, file }

enum ConferencingProvider { googleMeet, zoom, microsoftTeams, webex, other }

abstract class Link extends Equatable {
  const Link({required this.type});

  final LinkType type;

  factory Link.fromJson(Map<String, dynamic> json) {
    final type = LinkType.values.firstWhere(
      (t) => t.name == json['type'],
      orElse: () => LinkType.external,
    );

    switch (type) {
      case LinkType.external:
        return ExternalLink.fromJson(json);
      case LinkType.auth:
        return AuthLink.fromJson(json);
      case LinkType.callback:
        return CallbackLink.fromJson(json);
      case LinkType.conferencing:
        return ConferencingLink.fromJson(json);
      case LinkType.file:
        return FileLink.fromJson(json);
    }
  }

  Map<String, dynamic> toJson();
}

class ExternalLink extends Link {
  const ExternalLink({required this.title, required this.url})
    : super(type: LinkType.external);

  final String title;
  final String url;

  factory ExternalLink.fromJson(Map<String, dynamic> json) {
    return ExternalLink(
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

class AuthLink extends Link {
  const AuthLink({
    required this.title,
    required this.provider,
    required this.scopes,
    required this.callback,
  }) : super(type: LinkType.auth);

  final String title;
  final AuthProvider provider;
  final List<String> scopes;
  final String callback;

  factory AuthLink.fromJson(Map<String, dynamic> json) {
    return AuthLink(
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

class CallbackLink extends Link {
  const CallbackLink({required this.title, required this.callback})
    : super(type: LinkType.callback);

  final String title;
  final String callback;

  factory CallbackLink.fromJson(Map<String, dynamic> json) {
    return CallbackLink(
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

class ConferencingLink extends Link {
  const ConferencingLink({required this.url, required this.provider})
    : super(type: LinkType.conferencing);

  final String url;
  final ConferencingProvider provider;

  factory ConferencingLink.fromJson(Map<String, dynamic> json) {
    return ConferencingLink(
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

class FileLink extends Link {
  const FileLink({
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
  }) : super(type: LinkType.file);

  final String fileId;
  final String fileName;
  final int fileSize;
  final String mimeType;

  bool get isImage => mimeType.startsWith('image/');

  factory FileLink.fromJson(Map<String, dynamic> json) {
    return FileLink(
      fileId: json['fileId'] as String,
      fileName: json['fileName'] as String,
      fileSize: json['fileSize'] as int,
      mimeType: json['mimeType'] as String,
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
    };
  }

  @override
  List<Object?> get props => [type, fileId, fileName, fileSize, mimeType];
}

class LinksConverter extends TypeConverter<List<Link>?, String?>
    with JsonTypeConverter2<List<Link>?, String?, List<dynamic>?> {
  const LinksConverter();

  @override
  List<Link>? fromSql(String? fromDb) {
    if (fromDb == null || fromDb.isEmpty) {
      return null;
    }
    try {
      final dynamic jsonData = jsonDecode(fromDb);
      if (jsonData is List) {
        return jsonData
            .map((json) => Link.fromJson(json as Map<String, dynamic>))
            .toList();
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  @override
  String? toSql(List<Link>? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    return jsonEncode(value.map((link) => link.toJson()).toList());
  }

  @override
  List<Link>? fromJson(List<dynamic>? json) {
    if (json == null) {
      return null;
    }
    try {
      return json
          .map((item) => Link.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return null;
    }
  }

  @override
  List<dynamic>? toJson(List<Link>? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    return value.map((link) => link.toJson()).toList();
  }
}
