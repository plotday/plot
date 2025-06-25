import 'dart:math';

extension type Path(String value) {
  factory Path.generate({Path? parent}) {
    const characters =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    Random random = Random();
    String prefix = "";
    if (parent != null) {
      prefix = "${parent.value}.";
    }
    return Path(
      prefix +
          String.fromCharCodes(
            Iterable.generate(
              4,
              (_) => characters.codeUnitAt(random.nextInt(characters.length)),
            ),
          ),
    );
  }

  int get depth => value.split('.').length;

  bool get isRoot => !value.contains('.');

  Path? get parent {
    if (isRoot) return null;
    final segments = value.split('.');
    return Path(segments.take(segments.length - 1).join('.'));
  }

  Path get root => Path(value.split('.').first);

  bool isParent(Path other) => other.value.startsWith("$value.");
  bool isChild(Path? other) =>
      other == null || value.startsWith("${other.value}.");
}
