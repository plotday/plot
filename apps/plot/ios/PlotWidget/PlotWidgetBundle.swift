import SwiftUI
import WidgetKit

/// WidgetKit extension entry point for iOS.
///
/// The bundle declares a single minimal placeholder widget so the
/// extension compiles and ships. The placeholder is the smallest
/// surface that satisfies WidgetKit's "at least one Widget per
/// bundle" requirement — replace with real designed widgets when
/// they land.
@main
struct PlotWidgetBundle: WidgetBundle {
  var body: some Widget {
    PlotPlaceholderWidget()
  }
}

private struct PlotPlaceholderEntry: TimelineEntry {
  let date: Date
}

private struct PlotPlaceholderProvider: TimelineProvider {
  func placeholder(in context: Context) -> PlotPlaceholderEntry {
    PlotPlaceholderEntry(date: Date())
  }
  func getSnapshot(in context: Context, completion: @escaping (PlotPlaceholderEntry) -> Void) {
    completion(PlotPlaceholderEntry(date: Date()))
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<PlotPlaceholderEntry>) -> Void) {
    completion(Timeline(entries: [PlotPlaceholderEntry(date: Date())], policy: .never))
  }
}

private struct PlotPlaceholderWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: "day.plot.app.PlotWidget.placeholder",
      provider: PlotPlaceholderProvider()
    ) { _ in
      Text("Plot")
    }
    .configurationDisplayName("Plot")
    .description("Placeholder")
    .supportedFamilies([.systemSmall])
  }
}
