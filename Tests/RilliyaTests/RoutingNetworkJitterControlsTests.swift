import Foundation
import RilliyaRealtime
import Testing

@testable import Rilliya

@Suite("Routing network jitter controls")
struct RoutingNetworkJitterControlsTests {
  @Test("The defaults match what a wired local network needs")
  func defaultsResolveToTheLocalNetworkProfile() throws {
    let resolved = try RoutingNetworkJitterControls.initial.resolve()

    #expect(resolved.targetLatency == AudioJitterBufferConfiguration.localNetworkTarget)
    #expect(resolved.correction == .overlap)
  }

  @Test(
    "A chosen delay reaches the buffer",
    arguments: [
      RoutingNetworkJitterControls.minimumTargetMilliseconds,
      5,
      60,
      RoutingNetworkJitterControls.maximumTargetMilliseconds,
    ]
  )
  func targetDelayReachesTheBuffer(milliseconds: Int) throws {
    let controls = RoutingNetworkJitterControls(
      targetMilliseconds: milliseconds,
      correction: .overlap
    )

    #expect(try controls.resolve().targetLatency == .milliseconds(milliseconds))
  }

  @Test(
    "A chosen correction reaches the buffer",
    arguments: zip(
      RoutingNetworkJitterCorrection.allCases,
      [AudioJitterCorrection.overlap, .discard]
    )
  )
  func correctionReachesTheBuffer(
    correction: RoutingNetworkJitterCorrection,
    expected: AudioJitterCorrection
  ) throws {
    let controls = RoutingNetworkJitterControls(targetMilliseconds: 20, correction: correction)

    #expect(try controls.resolve().correction == expected)
  }

  /// The buffer refuses a target outside its own range, so the app's bounds have to stay inside it.
  @Test("Both ends of the range are values the buffer accepts")
  func rangeEndsAreAccepted() throws {
    for milliseconds in [
      RoutingNetworkJitterControls.minimumTargetMilliseconds,
      RoutingNetworkJitterControls.maximumTargetMilliseconds,
    ] {
      let controls = RoutingNetworkJitterControls(
        targetMilliseconds: milliseconds,
        correction: .overlap
      )
      #expect(throws: Never.self) { _ = try controls.resolve() }
    }
  }

  @Test("Controls round-trip through a saved workflow")
  func controlsSurvivePersistence() throws {
    let controls = RoutingNetworkJitterControls(targetMilliseconds: 45, correction: .discard)
    let encoded = try JSONEncoder().encode(controls)

    #expect(try JSONDecoder().decode(RoutingNetworkJitterControls.self, from: encoded) == controls)
  }

  /// A workflow saved before these controls existed has to keep opening.
  @Test("A receive configuration without jitter controls restores the defaults")
  func absentControlsRestoreDefaults() throws {
    let json = """
      {"port":48620,"sampleRate":48000,"channelCount":2}
      """
    let decoded = try JSONDecoder().decode(
      RoutingNetworkReceiveConfiguration.self,
      from: Data(json.utf8)
    )

    #expect(decoded.jitter == .initial)
    #expect(decoded.port == 48_620)
  }

  /// A hand-edited document must not crash the app, and must not reach the buffer with a value
  /// it would reject.
  @Test(
    "A delay outside the range is clamped rather than trusted",
    arguments: [-1, 0, 1, 10_000, Int.max]
  )
  func outOfRangeDelayIsClamped(milliseconds: Int) throws {
    let json = """
      {"targetMilliseconds":\(milliseconds),"correction":"overlap"}
      """
    let decoded = try JSONDecoder().decode(
      RoutingNetworkJitterControls.self,
      from: Data(json.utf8)
    )

    #expect(
      (RoutingNetworkJitterControls
        .minimumTargetMilliseconds...RoutingNetworkJitterControls
        .maximumTargetMilliseconds).contains(decoded.targetMilliseconds)
    )
    #expect(throws: Never.self) { _ = try decoded.resolve() }
  }

  @Test("An unreadable correction falls back rather than failing the whole document")
  func unknownCorrectionFallsBack() throws {
    let json = """
      {"targetMilliseconds":30}
      """
    let decoded = try JSONDecoder().decode(
      RoutingNetworkJitterControls.self,
      from: Data(json.utf8)
    )

    #expect(decoded.correction == RoutingNetworkJitterControls.initial.correction)
    #expect(decoded.targetMilliseconds == 30)
  }
}
