package day.plot.app.widgets

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONException
import org.json.JSONObject

/**
 * Single source of truth for the SharedPreferences file the Flutter
 * `MethodChannel('day.plot/widgets')` plugin writes to and the
 * AppWidgetProvider reads from.
 *
 * Kept process-safe by using `MODE_PRIVATE` and re-opening on every
 * call — the AppWidget framework may instantiate the provider in a
 * fresh process where the app's other state is not loaded.
 */
object WidgetSharedStorage {
  const val PREFS_NAME = "day.plot.widgets"
  const val WIDGET_STATE_KEY = "widgetState"

  fun prefs(context: Context): SharedPreferences =
    context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

  fun writeState(context: Context, json: String) {
    prefs(context).edit().putString(WIDGET_STATE_KEY, json).apply()
  }

  /** Returns the decoded widget state JSON, or null if unset / unreadable. */
  fun readState(context: Context): Map<String, Any?>? {
    val raw = prefs(context).getString(WIDGET_STATE_KEY, null) ?: return null
    return try {
      val obj = JSONObject(raw)
      val out = mutableMapOf<String, Any?>()
      obj.keys().forEach { key ->
        out[key] = if (obj.isNull(key)) null else obj.get(key)
      }
      out
    } catch (e: JSONException) {
      null
    }
  }
}
