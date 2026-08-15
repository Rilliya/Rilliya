import FlowingDayControls
import Foundation

enum RoutingAccentID: String, CaseIterable, Codable, Hashable, Sendable {
  case coral, poppy, crimson, cherry, petal, rose, berry
  case peach, citrus, tangerine, nectar, apricot, amber, marigold
  case butter, honey, pollen, sunbeam, daffodil, yuzu, lemon
  case leaf, sage, sprout, meadow, clover, fern, mint
  case dew, seafoam, lagoon, tide, celadon, ripple, mist
  case glacier, brook, sky, rain, breeze, bluebell, evening
  case wisteria, bloom, plum, iris, lilac, violet, fuchsia

  var displayName: String {
    rawValue.prefix(1).uppercased() + rawValue.dropFirst()
  }

  var accent: FlowingAccent {
    switch self {
    case .coral: .coral
    case .poppy: .poppy
    case .crimson: .crimson
    case .cherry: .cherry
    case .petal: .petal
    case .rose: .rose
    case .berry: .berry
    case .peach: .peach
    case .citrus: .citrus
    case .tangerine: .tangerine
    case .nectar: .nectar
    case .apricot: .apricot
    case .amber: .amber
    case .marigold: .marigold
    case .butter: .butter
    case .honey: .honey
    case .pollen: .pollen
    case .sunbeam: .sunbeam
    case .daffodil: .daffodil
    case .yuzu: .yuzu
    case .lemon: .lemon
    case .leaf: .leaf
    case .sage: .sage
    case .sprout: .sprout
    case .meadow: .meadow
    case .clover: .clover
    case .fern: .fern
    case .mint: .mint
    case .dew: .dew
    case .seafoam: .seafoam
    case .lagoon: .lagoon
    case .tide: .tide
    case .celadon: .celadon
    case .ripple: .ripple
    case .mist: .mist
    case .glacier: .glacier
    case .brook: .brook
    case .sky: .sky
    case .rain: .rain
    case .breeze: .breeze
    case .bluebell: .bluebell
    case .evening: .evening
    case .wisteria: .wisteria
    case .bloom: .bloom
    case .plum: .plum
    case .iris: .iris
    case .lilac: .lilac
    case .violet: .violet
    case .fuchsia: .fuchsia
    }
  }

  var baseRGB: UInt32 {
    switch self {
    case .coral: 0xCE7B62
    case .poppy: 0xE96452
    case .crimson: 0xDF6B6F
    case .cherry: 0xE66176
    case .petal: 0xD67084
    case .rose: 0xD0748B
    case .berry: 0xDD62A7
    case .peach: 0xC3896B
    case .citrus: 0xC58458
    case .tangerine: 0xC58347
    case .nectar: 0xBB8C5B
    case .apricot: 0xB18D62
    case .amber: 0xB48C4A
    case .marigold: 0xB48F40
    case .butter: 0xA89565
    case .honey: 0xAC9326
    case .pollen: 0xA6974F
    case .sunbeam: 0xA49A54
    case .daffodil: 0xA29A41
    case .yuzu: 0xA09D3B
    case .lemon: 0x9CA12F
    case .leaf: 0x74A629
    case .sage: 0x76A454
    case .sprout: 0x60AB32
    case .meadow: 0x69A75F
    case .clover: 0x38AF55
    case .fern: 0x58A97B
    case .mint: 0x5EA88F
    case .dew: 0x66A49B
    case .seafoam: 0x4DA5A0
    case .lagoon: 0x3FA4A4
    case .tide: 0x59A3A7
    case .celadon: 0x6D9EA5
    case .ripple: 0x59A4B2
    case .mist: 0x72A3AF
    case .glacier: 0x56A4B7
    case .brook: 0x29A3C5
    case .sky: 0x62A4CA
    case .rain: 0x6CA0D3
    case .breeze: 0x6F92DE
    case .bluebell: 0x708DE5
    case .evening: 0x848CCF
    case .wisteria: 0x968AC7
    case .bloom: 0x9F82D5
    case .plum: 0xA483C7
    case .iris: 0xB86EE2
    case .lilac: 0xB681C6
    case .violet: 0xC868D4
    case .fuchsia: 0xCD6EB6
    }
  }

  var paletteIndex: Int {
    Self.allCases.firstIndex(of: self) ?? 0
  }

  static let families: [(name: String, accents: [RoutingAccentID])] = [
    ("Red & Pink", [.coral, .poppy, .crimson, .cherry, .petal, .rose, .berry]),
    ("Orange", [.peach, .citrus, .tangerine, .nectar, .apricot, .amber, .marigold]),
    ("Yellow", [.butter, .honey, .pollen, .sunbeam, .daffodil, .yuzu, .lemon]),
    ("Green", [.leaf, .sage, .sprout, .meadow, .clover, .fern, .mint]),
    ("Teal", [.dew, .seafoam, .lagoon, .tide, .celadon, .ripple, .mist]),
    ("Blue", [.glacier, .brook, .sky, .rain, .breeze, .bluebell, .evening]),
    ("Purple", [.wisteria, .bloom, .plum, .iris, .lilac, .violet, .fuchsia]),
  ]
}

enum RoutingNodeKind: String, CaseIterable, Codable, Hashable, Sendable {
  case applicationAudio
  case inputAudio
  case outputAudio
  case visualizer
  case audioMixer
  case peakLevel
  case signalGenerator
  case delay
  case noiseGate

  var title: String {
    switch self {
    case .applicationAudio: "Application Audio"
    case .inputAudio: "Input Audio"
    case .outputAudio: "Output Audio"
    case .visualizer: "Visualizer"
    case .audioMixer: "Audio Mixer"
    case .peakLevel: "Peak Level"
    case .signalGenerator: "Signal Generator"
    case .delay: "Delay"
    case .noiseGate: "Noise Gate"
    }
  }

  var systemImage: String {
    switch self {
    case .applicationAudio: "macwindow.on.rectangle"
    case .inputAudio: "waveform.badge.mic"
    case .outputAudio: "speaker.wave.2"
    case .visualizer: "waveform"
    case .audioMixer: "slider.horizontal.3"
    case .peakLevel: "gauge.with.dots.needle.50percent"
    case .signalGenerator: "waveform.path"
    case .delay: "clock.arrow.trianglehead.counterclockwise.rotate.90"
    case .noiseGate: "waveform.badge.minus"
    }
  }

  var builtInAccentID: RoutingAccentID {
    switch self {
    case .applicationAudio: .fern
    case .inputAudio, .outputAudio: .brook
    case .visualizer: .seafoam
    case .audioMixer, .peakLevel: .pollen
    case .signalGenerator: .poppy
    case .delay: .wisteria
    case .noiseGate: .lagoon
    }
  }
}

extension RoutingNodeValue {
  var kind: RoutingNodeKind {
    switch self {
    case .applicationAudio: .applicationAudio
    case .inputAudio: .inputAudio
    case .outputAudio: .outputAudio
    case .visualizer: .visualizer
    case .audioMixer: .audioMixer
    case .peakLevel: .peakLevel
    case .signalGenerator: .signalGenerator
    case .delay: .delay
    case .noiseGate: .noiseGate
    }
  }
}

enum RoutingNodeAccentResolver {
  static func resolve(
    nodeOverride: RoutingAccentID?,
    typeOverride: RoutingAccentID?,
    kind: RoutingNodeKind
  ) -> RoutingAccentID {
    nodeOverride ?? typeOverride ?? kind.builtInAccentID
  }
}
