import Testing

@testable import Rilliya

struct RoutingVisualizerModeRoleTests {
  @Test func modeRowsRemainOrderedAndNamed() {
    #expect(RoutingVisualizerModeRole.allCases.map(\.title) == ["Input", "Display", "Output"])
  }

  @Test func modeRowsExposeUnambiguousAccessibilityLabels() {
    #expect(RoutingVisualizerModeRole.input.accessibilityLabel == "Visualizer input presentation")
    #expect(RoutingVisualizerModeRole.display.accessibilityLabel == "Waveform presentation")
    #expect(RoutingVisualizerModeRole.output.accessibilityLabel == "Visualizer output presentation")
  }
}
