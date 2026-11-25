import SwiftUI
import WidgetKit

/// Home screen / Lock Screen widget: server, group and who spoke last.
struct StatusWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "TetraStatus", provider: StatusProvider()) { entry in
      StatusWidgetView(entry: entry)
    }
    .configurationDisplayName("TETRA Terminal")
    .description("Server, talkgroup and who is talking.")
    .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
  }
}

struct StatusEntry: TimelineEntry {
  let date: Date
  let status: TetraStatus?
}

struct StatusProvider: TimelineProvider {
  func placeholder(in context: Context) -> StatusEntry { StatusEntry(date: Date(), status: .sample) }

  func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
    completion(StatusEntry(date: Date(), status: TetraShared.loadStatus() ?? .sample))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
    // The app reloads the timeline when something changes.
    completion(Timeline(entries: [StatusEntry(date: Date(), status: TetraShared.loadStatus())], policy: .never))
  }
}

struct StatusWidgetView: View {
  let entry: StatusEntry
  @Environment(\.widgetFamily) private var family
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    content.widgetBackground()
  }

  @ViewBuilder private var content: some View {
    if let s = entry.status {
      switch family {
      case .accessoryInline:
        Text("\(s.group) · \(s.talker ?? s.server)")
      case .accessoryRectangular:
        VStack(alignment: .leading, spacing: 1) {
          Label(s.group, systemImage: Palette.symbol(s)).font(.headline).lineLimit(1)
          talkerLine(s).lineLimit(1)
          Text(s.server).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      default:
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Image(systemName: Palette.symbol(s))
              .font(.system(size: 20, weight: .semibold))
              .foregroundStyle(Palette.tint(s, dark: scheme == .dark))
            Spacer()
            Circle().fill(s.online ? Color.green : Color.gray).frame(width: 8, height: 8)
          }
          Spacer(minLength: 4)
          Text(s.group).font(.headline).lineLimit(family == .systemSmall ? 2 : 1)
          talkerLine(s).font(.subheadline).foregroundStyle(s.talker != nil ? Color.primary : Color.secondary).lineLimit(1)
          Text(s.server).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      }
    } else {
      VStack(spacing: 6) {
        Image(systemName: "antenna.radiowaves.left.and.right").font(.title2)
        Text("Open TETRA Terminal").font(.caption).multilineTextAlignment(.center)
      }
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private func talkerLine(_ s: TetraStatus) -> some View {
    if let talker = s.talker, let since = s.talkerSince {
      Text("\(talker) · ") + Text(since, style: .timer)
    } else if let last = s.lastTalker, let at = s.lastTalkerAt {
      Text("\(last) · ") + Text(at, style: .time)
    } else {
      Text(s.online ? "Quiet" : "Offline")
    }
  }
}

extension View {
  @ViewBuilder func widgetBackground() -> some View {
    if #available(iOS 17.0, *) {
      containerBackground(.background, for: .widget)
    } else {
      background(Color(UIColor.systemBackground))
    }
  }
}
