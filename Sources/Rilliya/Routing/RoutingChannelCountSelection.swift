import Foundation

enum RoutingChannelCountChoice: Hashable, Sendable {
  case preset(Int)
  case custom
}

enum RoutingChannelCountSelection {
  static let commonPresets = [1, 2, 4, 6, 8]

  static func choice(for channelCount: Int) -> RoutingChannelCountChoice {
    commonPresets.contains(channelCount) ? .preset(channelCount) : .custom
  }

  static func label(for channelCount: Int) -> String {
    channelCount == 1 ? "Mono" : "\(channelCount) ch"
  }

  static func validatedCustomCount(
    _ text: String,
    in range: ClosedRange<Int>
  ) -> Int? {
    guard let count = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
      range.contains(count)
    else { return nil }
    return count
  }
}
