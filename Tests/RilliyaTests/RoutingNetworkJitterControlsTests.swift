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

  @Test("Common network conditions have presets and every other delay is custom")
  func targetDelayChoices() {
    #expect(RoutingNetworkJitterTargetSelection.presets == [5, 20, 50])
    #expect(RoutingNetworkJitterTargetSelection.choice(for: 5) == .preset(5))
    #expect(RoutingNetworkJitterTargetSelection.choice(for: 20) == .preset(20))
    #expect(RoutingNetworkJitterTargetSelection.choice(for: 50) == .preset(50))
    #expect(RoutingNetworkJitterTargetSelection.choice(for: 2) == .custom)
    #expect(RoutingNetworkJitterTargetSelection.choice(for: 500) == .custom)
  }

  @Test("A custom delay must be a whole number inside the supported range")
  func customTargetValidation() {
    #expect(RoutingNetworkJitterTargetSelection.validatedCustomTarget(" 275 ") == 275)
    #expect(RoutingNetworkJitterTargetSelection.validatedCustomTarget("1") == nil)
    #expect(RoutingNetworkJitterTargetSelection.validatedCustomTarget("501") == nil)
    #expect(RoutingNetworkJitterTargetSelection.validatedCustomTarget("20.5") == nil)
    #expect(RoutingNetworkJitterTargetSelection.validatedCustomTarget("fast") == nil)
  }

  @Test("A large custom target reserves enough receive storage")
  func customTargetReservesReceiveStorage() throws {
    let controls = RoutingNetworkJitterControls(targetMilliseconds: 500, correction: .overlap)
    let capacity = controls.requiredReceiveCapacityFrameCount(sampleRate: 96_000)

    #expect(capacity == 52_800)
    #expect(capacity <= AudioRealtimeFrameBuffer.maximumCapacityFrameCount)
    #expect(try controls.resolve().targetLatency == .milliseconds(500))
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

}

/// Adopting the sender's format saves the user from matching two machines by hand.
///
/// A receiver is built around one format, so a listener whose settings do not match the sender
/// rejects every packet and reports only that nothing arrived.
@Suite("Routing network automatic format")
struct RoutingNetworkAutomaticFormatTests {
  @Test("The choice round-trips through a saved workflow")
  func choiceSurvivesPersistence() throws {
    let configuration = RoutingNetworkReceiveConfiguration(
      port: 48_620,
      sampleRate: 96_000,
      channelCount: 8,
      adoptsSenderFormat: true
    )

    let encoded = try JSONEncoder().encode(configuration)
    let decoded = try JSONDecoder().decode(
      RoutingNetworkReceiveConfiguration.self,
      from: encoded
    )

    #expect(decoded == configuration)
    #expect(decoded.adoptsSenderFormat)
  }

  /// Switching the option off has to leave a format to fall back to, so the stored one stays.
  @Test("The stored format is kept while the sender's is being used")
  func storedFormatSurvivesAdoption() {
    var configuration = RoutingNetworkReceiveConfiguration(
      port: 48_620,
      sampleRate: 44_100,
      channelCount: 1
    )

    configuration.adoptsSenderFormat = true

    #expect(configuration.sampleRate == 44_100)
    #expect(configuration.channelCount == 1)
  }

  /// The listener has to be rebuilt around whatever the sender turns out to be using, so the
  /// choice must be part of what the controller compares.
  @Test("Changing the choice is a different configuration")
  func choiceChangesTheConfiguration() {
    let manual = RoutingNetworkReceiveConfiguration(
      port: 48_620,
      sampleRate: 48_000,
      channelCount: 2
    )
    var automatic = manual
    automatic.adoptsSenderFormat = true

    #expect(manual != automatic)
  }
}
