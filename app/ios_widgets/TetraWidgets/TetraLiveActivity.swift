import AppIntents
import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen banner and Dynamic Island while connected.
/// Talking: talker, group and timer. Standby: server, own callsign and ISSI.
struct TetraLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TetraActivityAttributes.self) { context in
      LockScreenActivityView(status: context.state)
        // Frosted dark glass: the system blurs the wallpaper behind the banner,
        // this tint lets only a little of it through (HIG: custom background
        // only on the Lock Screen, with enough contrast).
        .activityBackgroundTint(Color(white: 0.04).opacity(0.86))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      let s = context.state
      let tint = Palette.tint(s)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: Palette.symbol(s))
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .glass(tint, circle: true)
            .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          if let since = s.talkerSince {
            Text(since, style: .timer)
              .font(.title3.weight(.semibold))
              .monospacedDigit()
              .multilineTextAlignment(.trailing)
              .frame(width: 64, alignment: .trailing)
              .foregroundStyle(tint)
          } else {
            StatePill(status: s)
          }
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(spacing: 1) {
            Text(s.talker ?? s.server).font(.headline).lineLimit(1)
            Text(s.talker == nil ? s.ownLine : s.group).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack(spacing: 10) {
            Text(s.talker == nil ? s.group : s.server)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Spacer(minLength: 4)
            PttButton(status: s, compact: false)
          }
          .padding(.horizontal, 6)
        }
      } compactLeading: {
        TwoLines(
          top: s.talker ?? s.server,
          bottom: s.group,
          topColor: s.talker == nil ? .primary : tint)
          .frame(maxWidth: 78, alignment: .leading)
      } compactTrailing: {
        if let since = s.talkerSince {
          VStack(alignment: .trailing, spacing: 0) {
            Text(since, style: .timer)
              .font(.system(size: 12, weight: .semibold))
              .monospacedDigit()
              .multilineTextAlignment(.trailing)
              .foregroundStyle(tint)
            Text(s.emergency ? "SOS" : (s.transmitting ? "TX" : "RX"))
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(.secondary)
          }
          .frame(width: 44, alignment: .trailing)
        } else {
          TwoLines(top: s.ownName?.isEmpty == false ? s.ownName! : "Standby",
                   bottom: s.ownIssi.map(String.init) ?? "",
                   topColor: .primary, alignment: .trailing)
            .frame(maxWidth: 78, alignment: .trailing)
        }
      } minimal: {
        Image(systemName: Palette.symbol(s)).foregroundStyle(tint)
      }
      .keylineTint(tint)
    }
  }
}

/// Two small lines for the compact Dynamic Island.
struct TwoLines: View {
  let top: String
  let bottom: String
  var topColor: Color = .primary
  var alignment: HorizontalAlignment = .leading

  var body: some View {
    VStack(alignment: alignment, spacing: 0) {
      Text(top).font(.system(size: 12, weight: .semibold)).foregroundStyle(topColor)
      if !bottom.isEmpty {
        Text(bottom).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
      }
    }
    .lineLimit(1)
    .minimumScaleFactor(0.8)
  }
}

/// "STANDBY" / "OFFLINE" next to the server name, like the status pills of iOS.
struct StatePill: View {
  let status: TetraStatus
  var body: some View {
    let online = status.online
    let tint = online ? Palette.accent : Color.gray
    Text(online ? "STANDBY" : "OFFLINE")
      .font(.system(size: 10, weight: .bold))
      .foregroundStyle(tint)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .glass(tint, circle: false)
  }
}

/// Tap to transmit, tap again to stop (Live Activity buttons cannot be held).
struct PttButton: View {
  let status: TetraStatus
  let compact: Bool
  /// Full-width bar under the Lock Screen banner.
  var wide = false

  var body: some View {
    if #available(iOS 17.0, *) {
      if status.transmitting || status.canTalk == true {
      let tint = status.transmitting ? Palette.talk : Palette.accent
      Button(intent: TogglePttIntent()) {
        HStack(spacing: 6) {
          Image(systemName: status.transmitting ? "stop.fill" : "mic.fill")
            .font(.system(size: compact ? 18 : 15, weight: .semibold))
          if wide {
            Text(status.transmitting ? "Stop" : "Push to talk")
            if status.transmitting, let end = status.txEndsAt {
              Text(timerInterval: Date()...max(end, Date()), countsDown: true)
                .monospacedDigit()
                .frame(width: 44)
                .opacity(0.85)
            }
          } else if !compact {
            if status.transmitting, let end = status.txEndsAt {
              Text(timerInterval: Date()...max(end, Date()), countsDown: true)
                .monospacedDigit()
                .frame(width: 40)
            } else {
              Text(status.transmitting ? "Stop" : "Talk")
            }
          }
        }
        .font(.system(size: wide ? 17 : 15, weight: .semibold))
        .foregroundStyle(Color.white)
        .frame(maxWidth: wide ? .infinity : nil)
        .frame(width: compact && !wide ? 48 : nil, height: wide ? 50 : (compact ? 48 : 36))
        .padding(.horizontal, compact || wide ? 0 : 14)
        .background(tint, in: wide ? AnyShape(ContainerRelativeShape()) : AnyShape(Capsule()))
      }
      .buttonStyle(.plain)
      }
    }
  }
}

extension View {
  /// A tinted round or capsule fill. Not `glassEffect`: in a Live Activity
  /// (widget extension) the glass renders nothing on the Lock Screen, so the
  /// views it wraps disappeared. The system already draws the activity on its
  /// own glass/material background on iOS 26.
  @ViewBuilder
  func glass(_ tint: Color, circle: Bool) -> some View {
    if circle {
      self.background(tint.opacity(0.22), in: Circle())
    } else {
      self.background(tint.opacity(0.22), in: Capsule())
    }
  }
}

struct LockScreenActivityView: View {
  let status: TetraStatus

  /// Lock Screen banner, up to the 160 pt the system allows: a small header
  /// (server + state), the talker or own callsign large with the timer, the
  /// group, and the PTT bar. Always light-on-dark over the frosted tint.
  var body: some View {
    let tint = Palette.tint(status)
    VStack(alignment: .leading, spacing: 0) {
      // Header: server and state.
      HStack(spacing: 6) {
        Image(systemName: "antenna.radiowaves.left.and.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Palette.accent)
        Text(status.server)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white.opacity(0.6))
          .lineLimit(1)
        Spacer(minLength: 8)
        StateBadge(status: status)
      }
      Spacer(minLength: 6)
      // Main line: who talks (or who I am) and for how long.
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        VStack(alignment: .leading, spacing: 1) {
          Text(status.talker ?? (status.ownName?.isEmpty == false ? status.ownName! : "Standby"))
            .font(.system(size: 26, weight: .bold, design: .rounded))
            .foregroundStyle(status.talker == nil ? Color.white : tint)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          Text(secondLine)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        if let since = status.talkerSince {
          Text(since, style: .timer)
            .font(.system(size: 34, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(width: 96, alignment: .trailing)
            .foregroundStyle(tint)
        }
      }
      Spacer(minLength: 10)
      PttButton(status: status, compact: true, wide: true)
    }
    .padding(14)
    .frame(minHeight: 150)
    .environment(\.colorScheme, .dark)
  }

  private var secondLine: String {
    if status.talker != nil { return status.emergency ? "Emergency · \(status.group)" : status.group }
    let issi = status.ownIssi.map { "ISSI \($0)" }
    return [issi, status.group].compactMap { $0 }.joined(separator: " · ")
  }
}

/// RX / TX / SOS / STANDBY / OFFLINE, as a small tinted capsule.
struct StateBadge: View {
  let status: TetraStatus
  var body: some View {
    let (label, color): (String, Color) = {
      if status.emergency { return ("SOS", Palette.emergency) }
      if status.transmitting { return ("TX", Palette.talk) }
      if status.talker != nil { return ("RX", Palette.accent) }
      return status.online ? ("STANDBY", Palette.accent) : ("OFFLINE", .gray)
    }()
    Text(label)
      .font(.system(size: 11, weight: .bold))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(color.opacity(0.18), in: Capsule())
  }
}
