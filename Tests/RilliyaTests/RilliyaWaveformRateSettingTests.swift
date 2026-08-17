import Foundation
import RilliyaRealtime
import Testing

@testable import Rilliya

/// How often a waveform reports, which the person using the application chooses.
///
/// Three rates are offered because displays run at them. Anything else is theirs to type: a rate a
/// machine cannot keep up with is a choice this is not entitled to overrule, so the only value
/// refused is one that would report nothing at all.
@Suite("Waveform rate setting", .serialized)
@MainActor
struct RilliyaWaveformRateSettingTests {
  private static func settings() -> RilliyaSettings {
    let defaults = UserDefaults(suiteName: "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)")
    return RilliyaSettings(defaults: defaults ?? .standard)
  }

  @Test("Thirty a second unless something else was chosen")
  func defaultsToThirty() {
    #expect(Self.settings().waveformUpdatesPerSecond == 30)
    #expect(AudioWaveformMeter.defaultUpdatesPerSecond == 30)
  }

  @Test("The rates offered are the ones displays run at")
  func presetsAreDisplayRates() {
    #expect(RilliyaSettings.waveformUpdatePresets == [30, 60, 120])
  }

  @Test("A chosen rate is kept", arguments: [30, 60, 120])
  func presetIsKept(rate: Int) {
    let settings = Self.settings()
    settings.waveformUpdatesPerSecond = rate

    #expect(settings.waveformUpdatesPerSecond == rate)
  }

  /// The point of the custom field: a number nobody foresaw is still allowed.
  @Test("A rate nobody offered is allowed", arguments: [1, 7, 45, 240, 1_000, 100_000])
  func unusualRateIsAllowed(rate: Int) {
    let settings = Self.settings()
    settings.waveformUpdatesPerSecond = rate

    #expect(settings.waveformUpdatesPerSecond == rate, "\(rate) was overruled")
  }

  /// The one bound, and it exists because below it nothing would ever be reported.
  @Test("A rate that would report nothing is held at one", arguments: [0, -1, -1_000])
  func nonPositiveRateIsHeld(rate: Int) {
    let settings = Self.settings()
    settings.waveformUpdatesPerSecond = rate

    #expect(settings.waveformUpdatesPerSecond == RilliyaSettings.minimumWaveformUpdatesPerSecond)
    #expect(RilliyaSettings.minimumWaveformUpdatesPerSecond == 1)
  }

  @Test("A chosen rate survives a restart")
  func rateIsRemembered() {
    let name = "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)"
    let defaults = try? #require(UserDefaults(suiteName: name))
    guard let defaults else { return }

    RilliyaSettings(defaults: defaults).waveformUpdatesPerSecond = 240

    #expect(RilliyaSettings(defaults: defaults).waveformUpdatesPerSecond == 240)
  }

  /// Whatever is chosen has to produce an interval a meter can actually run at.
  @Test("Every rate reaches the meter as a usable interval")
  func rateReachesTheMeter() {
    let settings = Self.settings()
    for rate in [1, 30, 60, 120, 240, 1_000, 100_000] {
      settings.waveformUpdatesPerSecond = rate
      let interval = AudioWaveformMeter.interval(
        forUpdatesPerSecond: settings.waveformUpdatesPerSecond)

      #expect(interval > .zero, "\(rate) gave an interval of nothing")
    }
  }
}
