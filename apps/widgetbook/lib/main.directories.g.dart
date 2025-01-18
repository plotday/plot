// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_import, prefer_relative_imports, directives_ordering

// GENERATED CODE - DO NOT MODIFY BY HAND

// **************************************************************************
// AppGenerator
// **************************************************************************

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'package:plot_widgetbook/activity.dart' as _i2;
import 'package:plot_widgetbook/list_tile.dart' as _i3;
import 'package:widgetbook/widgetbook.dart' as _i1;

final directories = <_i1.WidgetbookNode>[
  _i1.WidgetbookFolder(
    name: 'widget',
    children: [
      _i1.WidgetbookComponent(
        name: 'ActivityWidget',
        useCases: [
          _i1.WidgetbookUseCase(
            name: 'Do now',
            builder: _i2.buildActivityDoNow,
          ),
          _i1.WidgetbookUseCase(
            name: 'Plain',
            builder: _i2.buildActivity,
          ),
        ],
      ),
      _i1.WidgetbookComponent(
        name: 'ListTile',
        useCases: [
          _i1.WidgetbookUseCase(
            name: 'Leading',
            builder: _i3.buildListTileLeading,
          ),
          _i1.WidgetbookUseCase(
            name: 'Selected',
            builder: _i3.buildListTileSelected,
          ),
          _i1.WidgetbookUseCase(
            name: 'Title only',
            builder: _i3.buildListTile,
          ),
        ],
      ),
    ],
  )
];
