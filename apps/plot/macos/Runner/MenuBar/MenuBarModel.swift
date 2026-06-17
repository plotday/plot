import Foundation
import SwiftUI

struct MBFocus: Identifiable, Equatable {
  let focusId: String
  let focusName: String
  let roleName: String?
  let colorHex: String?
  var id: String { focusId }
}

struct MBEvent: Equatable {
  let threadId: String
  let title: String
  let startIso: String
  let endIso: String?
  let hasCall: Bool
}

struct MBTodo: Identifiable, Equatable {
  let threadId: String
  let title: String
  var id: String { threadId }
}

final class MenuBarModel: ObservableObject {
  @Published var isSignedIn = false
  @Published var title: String?
  @Published var titleIsTimer = false
  @Published var timerTitlePrefix: String?
  @Published var currentFocus: MBFocus?
  @Published var currentEvent: MBEvent?
  @Published var nextEvent: MBEvent?
  @Published var todos: [MBTodo] = []
  @Published var focuses: [MBFocus] = []

  /// Set by the controller so SwiftUI rows can emit actions back to Flutter.
  var onAction: ((String, [String: Any]) -> Void)?
  /// Set by the controller to handle Quit requests from the footer.
  var onQuit: (() -> Void)?

  func apply(_ d: [String: Any]) {
    isSignedIn = (d["isSignedIn"] as? Bool) ?? false
    title = d["title"] as? String
    titleIsTimer = (d["titleIsTimer"] as? Bool) ?? false
    timerTitlePrefix = d["timerTitlePrefix"] as? String
    currentFocus = Self.focus(d["currentFocus"] as? [String: Any])
    currentEvent = Self.event(d["currentEvent2"] as? [String: Any])
    nextEvent = Self.event(d["nextEvent2"] as? [String: Any])
    todos = (d["todos"] as? [[String: Any]] ?? []).compactMap {
      guard let id = $0["threadId"] as? String,
            let t = $0["title"] as? String else { return nil }
      return MBTodo(threadId: id, title: t)
    }
    focuses = (d["focuses"] as? [[String: Any]] ?? []).compactMap { Self.focus($0) }
  }

  private static func focus(_ d: [String: Any]?) -> MBFocus? {
    guard let d, let id = d["focusId"] as? String,
          let name = d["focusName"] as? String else { return nil }
    return MBFocus(focusId: id, focusName: name,
                   roleName: d["roleName"] as? String,
                   colorHex: d["colorHex"] as? String)
  }

  private static func event(_ d: [String: Any]?) -> MBEvent? {
    guard let d, let id = d["threadId"] as? String,
          let t = d["title"] as? String,
          let s = d["startIso"] as? String else { return nil }
    return MBEvent(threadId: id, title: t, startIso: s,
                   endIso: d["endIso"] as? String,
                   hasCall: (d["hasCall"] as? Bool) ?? false)
  }
}
