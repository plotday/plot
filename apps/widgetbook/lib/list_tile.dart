import 'package:flutter/widgets.dart';
import 'package:widgetbook_annotation/widgetbook_annotation.dart' as widgetbook;

import 'package:plot/widget/list_tile.dart';

@widgetbook.UseCase(name: 'Title only', type: ListTile)
Widget buildListTile(BuildContext context) {
  return ListTile(
    title: const Text('Title'),
  );
}

@widgetbook.UseCase(name: 'Leading', type: ListTile)
Widget buildListTileLeading(BuildContext context) {
  return ListTile(
    leading: const Text('Leading'),
    title: const Text('Title'),
  );
}
