import Foundation

enum RoutingDynamicMonospacedText {
  static func glyphs(in value: String) -> [String] {
    value.map(String.init)
  }
}
