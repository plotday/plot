package day.plot.app.widgets

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android side of the `day.plot/widgets` MethodChannel.
 *
 * - `writeState({json})` persists the JSON-encoded `WidgetState` to
 *   shared storage so the AppWidgetProvider can read it.
 * - `reloadAll` triggers an immediate update for every active
 *   instance of [PlotAppWidgetProvider]. Today the provider is
 *   disabled in the manifest, so this is a no-op for end users; the
 *   plumbing is in place for when designs flip the provider on.
 *
 * Outbound `onWidgetAction` calls (sent from native back to Flutter)
 * are reserved for future widget tap handlers — none today.
 */
class WidgetBridgePlugin(
  private val context: Context,
  messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

  private val channel = MethodChannel(messenger, CHANNEL_NAME).apply {
    setMethodCallHandler(this@WidgetBridgePlugin)
  }

  fun sendAction(name: String, args: Map<String, Any?> = emptyMap()) {
    channel.invokeMethod("onWidgetAction", mapOf("name" to name, "args" to args))
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "writeState" -> {
        val json = call.argument<String>("json")
        if (json == null) {
          result.error("bad-args", "writeState requires {json}", null)
          return
        }
        WidgetSharedStorage.writeState(context, json)
        result.success(null)
      }
      "reloadAll" -> {
        val manager = AppWidgetManager.getInstance(context)
        val component = ComponentName(context, PlotAppWidgetProvider::class.java)
        val ids = manager.getAppWidgetIds(component)
        if (ids.isNotEmpty()) {
          val intent = android.content.Intent(context, PlotAppWidgetProvider::class.java).apply {
            action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
          }
          context.sendBroadcast(intent)
        }
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  companion object {
    const val CHANNEL_NAME = "day.plot/widgets"
  }
}
