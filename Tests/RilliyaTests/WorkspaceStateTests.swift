import Testing

@testable import Rilliya

struct WorkspaceStateTests {
  @Test
  func launchTransitionProducesReadyPresentation() {
    var state = WorkspaceState()

    #expect(state.phase == .preparing)
    #expect(state.presentation.status == "Preparing")

    state.completeLaunch()

    #expect(state.phase == .ready)
    #expect(
      state.presentation
        == WorkspacePresentation(
          phase: .ready
        )
    )
    #expect(state.presentation.status == "Ready")
    #expect(state.presentation.systemImage == "waveform.path")
  }
}
