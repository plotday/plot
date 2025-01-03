import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:widgetbook_annotation/widgetbook_annotation.dart' as widgetbook;
import 'package:injector/injector.dart';

import 'package:plot/widget/app.dart';
import 'package:plot/base.dart';

import 'main.directories.g.dart';

void main() {
  Injector.appInstance.registerSingleton<Base>(() => Base.disconnected());
  runApp(const WidgetbookApp());
}

@widgetbook.App()
class WidgetbookApp extends StatelessWidget {
  const WidgetbookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Widgetbook(
      directories: directories,
      appBuilder: (context, child) {
        return AppWidget(
          home: child,
        );
      },
    );
  }
}
