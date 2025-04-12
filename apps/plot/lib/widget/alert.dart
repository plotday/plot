import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;
import 'package:platform_builder/platform_builder.dart';

class Alert {
  static void show(BuildContext context, String message) {
    return PlatformResolver.current(
        macOSResolver: () => macos.showMacosAlertDialog<void>(
              context: context,
              builder: (_) => macos.MacosAlertDialog(
                appIcon: FlutterLogo(size: 64),
                title: Text(
                  'Plot',
                  style: macos.MacosTheme.of(context).typography.headline,
                ),
                message: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: macos.MacosTypography.of(context).headline,
                ),
                primaryButton: macos.PushButton(
                  controlSize: macos.ControlSize.large,
                  child: Text('Close'),
                  onPressed: () {
                    Navigator.of(context, rootNavigator: true).pop();
                  },
                ),
              ),
            ),
        defaultResolver: () =>
            material.ScaffoldMessenger.of(context).showSnackBar(
              material.SnackBar(
                content: Text(message),
                backgroundColor: material.Theme.of(context).colorScheme.error,
              ),
            ));
  }
}
