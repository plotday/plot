import 'package:flutter/widgets.dart';
import 'package:widgetbook_annotation/widgetbook_annotation.dart' as widgetbook;

import 'package:plot/widget/list_tile.dart' as plot;

@widgetbook.UseCase(name: 'Title only', type: plot.ListTile)
Widget buildListTile(BuildContext context) {
  return plot.ListTile(
    title: 'Title',
  );
}

@widgetbook.UseCase(name: 'With subtitle', type: plot.ListTile)
Widget buildListTileWithSubtitle(BuildContext context) {
  return plot.ListTile(
    title: 'Title',
    body: const Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Text('This is the subtitle content'),
    ),
  );
}

@widgetbook.UseCase(name: 'Selected', type: plot.ListTile)
Widget buildListTileSelected(BuildContext context) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      plot.ListTile(
        title: 'Selected Item',
        selected: true,
      ),
      plot.ListTile(
        title: 'Normal Item',
        selected: false,
      ),
    ],
  );
}

@widgetbook.UseCase(name: 'Header style', type: plot.ListTile)
Widget buildListTileHeader(BuildContext context) {
  return plot.ListTile(
    title: 'Section Header',
    style: plot.ListTileStyle.header,
  );
}
