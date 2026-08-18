enum RoutingVisualizerModeRole: CaseIterable, Hashable, Sendable {
  case input
  case display
  case output

  var title: String {
    switch self {
    case .input: "Input"
    case .display: "Display"
    case .output: "Output"
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .input: "Visualizer input presentation"
    case .display: "Waveform presentation"
    case .output: "Visualizer output presentation"
    }
  }
}
