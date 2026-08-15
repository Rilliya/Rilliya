import Foundation

enum RoutingPaletteSearch {
  static func matches(
    query: String,
    title: String,
    description: String
  ) -> Bool {
    let queryTokens = tokens(in: query)
    guard !queryTokens.isEmpty else { return true }

    let candidates = tokens(in: title) + tokens(in: description)
    let joinedCandidate = candidates.joined()
    return queryTokens.allSatisfy { queryToken in
      candidates.contains(where: { candidate in
        candidate.contains(queryToken) || isSubsequence(queryToken, of: candidate)
      }) || isSubsequence(queryToken, of: joinedCandidate)
    }
  }

  private static func tokens(in value: String) -> [String] {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
  }

  private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
    guard !needle.isEmpty else { return true }
    var iterator = haystack.makeIterator()
    return needle.allSatisfy { character in
      while let candidate = iterator.next() {
        if candidate == character { return true }
      }
      return false
    }
  }
}
