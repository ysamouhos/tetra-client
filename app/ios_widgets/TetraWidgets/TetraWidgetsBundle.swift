import SwiftUI
import WidgetKit

@main
struct TetraWidgetsBundle: WidgetBundle {
  var body: some Widget {
    StatusWidget()
    TetraLiveActivity()
  }
}

/// Colours of the app (lib/ui/theme.dart).
enum Palette {
  static let accent = Color(red: 0x3C / 255, green: 0xC7 / 255, blue: 0x9F / 255)
  static let accentLight = Color(red: 0x1F / 255, green: 0x8A / 255, blue: 0x70 / 255)
  static let talk = Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255)
  static let emergency = Color(red: 1, green: 0x3B / 255, blue: 0x30 / 255)

  static func tint(_ s: TetraStatus, dark: Bool = true) -> Color {
    if s.emergency { return emergency }
    if s.transmitting { return talk }
    return dark ? accent : accentLight
  }

  static func symbol(_ s: TetraStatus) -> String {
    if s.emergency { return "exclamationmark.triangle.fill" }
    if s.transmitting { return "mic.fill" }
    if s.talker != nil { return "waveform" }
    return "antenna.radiowaves.left.and.right"
  }
}
