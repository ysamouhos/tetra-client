import Flutter
import UIKit
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Channel "tetra/live": the Flutter side sends the radio status, this shows
/// it in the Live Activity and stores it for the home screen widget.
final class TetraLivePlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tetra/live", binaryMessenger: registrar.messenger())
    let plugin = TetraLivePlugin(channel: channel)
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }

  private let channel: FlutterMethodChannel

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    // The Live Activity PTT button (TogglePttIntent) runs in this process.
    NotificationCenter.default.addObserver(forName: .tetraTogglePtt, object: nil, queue: .main) { [weak self] _ in
      self?.channel.invokeMethod("togglePtt", arguments: nil)
    }
  }

  private var lastWidgetStatus: TetraStatus?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "update":
      let args = call.arguments as? [String: Any] ?? [:]
      let status = TetraStatus(flutter: args)
      updateWidget(status)
      if #available(iOS 16.2, *) {
        if args["live"] as? Bool ?? false {
          LiveActivityController.shared.show(status, profile: args["profile"] as? String ?? "")
        } else {
          LiveActivityController.shared.end()
        }
      }
      result(nil)
    case "end":
      if #available(iOS 16.2, *) { LiveActivityController.shared.end() }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func updateWidget(_ status: TetraStatus) {
    // The widget shows group, last talker and server; skip pure timer changes.
    var key = status
    key.talkerSince = nil
    key.txEndsAt = nil
    if key == lastWidgetStatus { return }
    lastWidgetStatus = key
    TetraShared.saveStatus(status)
    WidgetCenter.shared.reloadAllTimelines()
  }
}

extension TetraStatus {
  init(flutter a: [String: Any]) {
    func date(_ key: String) -> Date? {
      (a[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }
    self.init(
      server: a["server"] as? String ?? "",
      group: a["group"] as? String ?? "",
      talker: a["talker"] as? String,
      talkerSince: date("talkerSince"),
      transmitting: a["transmitting"] as? Bool ?? false,
      emergency: a["emergency"] as? Bool ?? false,
      online: a["online"] as? Bool ?? false,
      lastTalker: a["lastTalker"] as? String,
      lastTalkerAt: date("lastTalkerAt"),
      ownName: a["ownName"] as? String,
      ownIssi: (a["ownIssi"] as? NSNumber)?.intValue,
      canTalk: a["canTalk"] as? Bool,
      txEndsAt: date("txEndsAt"))
  }
}

#if canImport(ActivityKit)
@available(iOS 16.2, *)
final class LiveActivityController {
  static let shared = LiveActivityController()
  private var activity: Activity<TetraActivityAttributes>?

  func show(_ status: TetraStatus, profile: String) {
    let content = ActivityContent(state: status, staleDate: nil, relevanceScore: status.talker == nil ? 0 : 100)
    // After a restart the activity of the last run is still there: take it over.
    if activity == nil { activity = Activity<TetraActivityAttributes>.activities.first }
    if let current = activity, current.activityState == .active, current.attributes.profile == profile {
      Task { await current.update(content) }
      return
    }
    end()
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    // Starting needs the app in the foreground; updates also work in the background.
    activity = try? Activity.request(attributes: TetraActivityAttributes(profile: profile), content: content, pushType: nil)
  }

  func end() {
    let running = Activity<TetraActivityAttributes>.activities
    activity = nil
    guard !running.isEmpty else { return }
    Task {
      for a in running { await a.end(nil, dismissalPolicy: .immediate) }
    }
  }
}
#endif
