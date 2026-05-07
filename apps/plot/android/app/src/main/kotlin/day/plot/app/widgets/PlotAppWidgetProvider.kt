package day.plot.app.widgets

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.util.Log
import android.widget.RemoteViews
import day.plot.app.R

/**
 * Stub home-screen widget provider.
 *
 * Declared with `android:enabled="false"` in the manifest so it does
 * not appear in the system widget picker today. When designs land,
 * flip the manifest flag and replace [renderWidget] with the real
 * layout.
 *
 * Reads the JSON state Flutter writes to [WidgetSharedStorage]. The
 * provider runs in the app process when the app is alive, otherwise
 * in a separate process spun up by the AppWidget framework — either
 * way it only touches `SharedPreferences`, never the Drift database
 * or the Flutter engine.
 */
class PlotAppWidgetProvider : AppWidgetProvider() {
  override fun onUpdate(
    context: Context,
    appWidgetManager: AppWidgetManager,
    appWidgetIds: IntArray
  ) {
    val state = WidgetSharedStorage.readState(context)
    Log.i(TAG, "onUpdate ids=${appWidgetIds.toList()} state=$state")
    appWidgetIds.forEach { id ->
      val views = renderWidget(context, state)
      appWidgetManager.updateAppWidget(id, views)
    }
  }

  private fun renderWidget(context: Context, state: Map<String, Any?>?): RemoteViews {
    // Placeholder layout — empty FrameLayout. Real widget UI will be
    // designed and dropped in here, reading [state] for the current
    // priority etc.
    return RemoteViews(context.packageName, R.layout.plot_app_widget)
  }

  companion object {
    private const val TAG = "PlotAppWidget"
  }
}
