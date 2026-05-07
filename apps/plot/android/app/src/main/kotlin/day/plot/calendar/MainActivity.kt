package day.plot.app

import day.plot.app.widgets.WidgetBridgePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
  private var widgetBridgePlugin: WidgetBridgePlugin? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    widgetBridgePlugin = WidgetBridgePlugin(
      applicationContext,
      flutterEngine.dartExecutor.binaryMessenger
    )
  }
}
