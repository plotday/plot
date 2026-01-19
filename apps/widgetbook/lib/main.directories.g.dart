// dart format width=80
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_import, prefer_relative_imports, directives_ordering

// GENERATED CODE - DO NOT MODIFY BY HAND

// **************************************************************************
// AppGenerator
// **************************************************************************

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'package:plot_widgetbook/bidirectional_list.dart'
    as _plot_widgetbook_bidirectional_list;
import 'package:plot_widgetbook/list_tile.dart' as _plot_widgetbook_list_tile;
import 'package:widgetbook/widgetbook.dart' as _widgetbook;

final directories = <_widgetbook.WidgetbookNode>[
  _widgetbook.WidgetbookFolder(
    name: 'widget',
    children: [
      _widgetbook.WidgetbookComponent(
        name: 'BidirectionalList',
        useCases: [
          _widgetbook.WidgetbookUseCase(
            name: 'Add to start',
            builder: _plot_widgetbook_bidirectional_list.buildAddToStart,
          ),
          _widgetbook.WidgetbookUseCase(
            name: 'Insert before anchor',
            builder:
                _plot_widgetbook_bidirectional_list.buildInsertBeforeAnchor,
          ),
        ],
      ),
      _widgetbook.WidgetbookComponent(
        name: 'ListTile',
        useCases: [
          _widgetbook.WidgetbookUseCase(
            name: 'Header style',
            builder: _plot_widgetbook_list_tile.buildListTileHeader,
          ),
          _widgetbook.WidgetbookUseCase(
            name: 'Selected',
            builder: _plot_widgetbook_list_tile.buildListTileSelected,
          ),
          _widgetbook.WidgetbookUseCase(
            name: 'Title only',
            builder: _plot_widgetbook_list_tile.buildListTile,
          ),
          _widgetbook.WidgetbookUseCase(
            name: 'With subtitle',
            builder: _plot_widgetbook_list_tile.buildListTileWithSubtitle,
          ),
        ],
      ),
    ],
  )
];
