import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Shared by the app and the widget extension.
enum TetraShared {
  /// App Group for the home screen widget: "group." + the app's bundle id.
  static var appGroup: String {
    let app = Bundle.main.bundleIdentifier ?? "org.tetra.terminal.tetraTerminal"
    // The widget extension's id is the app's id + ".TetraWidgets".
    let base = app.hasSuffix(".TetraWidgets") ? String(app.dropLast(".TetraWidgets".count)) : app
    return "group.\(base)"
  }
  static let statusKey = "tetra.status"

  static func loadStatus() -> TetraStatus? {
    guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: statusKey) else { return nil }
    return try? JSONDecoder().decode(TetraStatus.self, from: data)
  }

  static func saveStatus(_ status: TetraStatus) {
    guard let defaults = UserDefaults(suiteName: appGroup), let data = try? JSONEncoder().encode(status) else { return }
    defaults.set(data, forKey: statusKey)
  }
}

/// What the app is doing right now: server, group, who talks and since when.
struct TetraStatus: Codable, Hashable, Sendable {
  var server: String
  var group: String
  var talker: String?
  var talkerSince: Date?
  var transmitting: Bool
  var emergency: Bool
  var online: Bool
  var lastTalker: String?
  var lastTalkerAt: Date?
  /// Standby line: own callsign and ISSI.
  var ownName: String?
  var ownIssi: Int?
  /// PTT button in the Live Activity: shown when the app may key up.
  var canTalk: Bool?
  /// Auto-stop of the Live Activity PTT; nil = off.
  var txEndsAt: Date?

  /// "OE1XYZ · 2320001", or just the ISSI.
  var ownLine: String {
    let issi = ownIssi.map(String.init) ?? ""
    guard let name = ownName, !name.isEmpty else { return issi }
    return issi.isEmpty ? name : "\(name) · \(issi)"
  }

  static let sample = TetraStatus(
    server: "TMO Austria", group: "Austria", talker: "OE1ABC", talkerSince: Date().addingTimeInterval(-12),
    transmitting: false, emergency: false, online: true, lastTalker: "OE1ABC", lastTalkerAt: Date(),
    ownName: "OE1XYZ", ownIssi: 2320001, canTalk: true, txEndsAt: nil)
}

extension Notification.Name {
  /// Posted in the app process by the Live Activity PTT button.
  static let tetraTogglePtt = Notification.Name("tetra.togglePtt")
}

#if canImport(AppIntents)
import AppIntents

/// The Live Activity PTT button: tap to transmit, tap again to stop. A
/// LiveActivityIntent runs in the app's process (which stays alive in the
/// background through its audio session), so the app can key up directly.
/// Hold-to-talk is not possible: Live Activity buttons only receive taps.
@available(iOS 17.0, *)
struct TogglePttIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "Push to talk"
  static var description = IntentDescription("Starts or stops transmitting on the selected talkgroup.")
  static var isDiscoverable = false

  init() {}

  func perform() async throws -> some IntentResult {
    await MainActor.run { NotificationCenter.default.post(name: .tetraTogglePtt, object: nil) }
    return .result()
  }
}
#endif

#if canImport(ActivityKit)
@available(iOS 16.2, *)
struct TetraActivityAttributes: ActivityAttributes {
  typealias ContentState = TetraStatus
  /// The connection profile the activity belongs to.
  var profile: String
}
#endif
