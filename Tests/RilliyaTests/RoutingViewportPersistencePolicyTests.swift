import FlowingDayCanvas
import Testing

@testable import Rilliya

struct RoutingViewportPersistencePolicyTests {
  @Test
  func continuousCameraChangesStayInsideTheMetalBackend() {
    #expect(!RoutingViewportPersistencePolicy.shouldPersist(phase: .continuous))
  }

  @Test
  func completedCameraChangesPersistIntoTheWorkflowSession() {
    #expect(RoutingViewportPersistencePolicy.shouldPersist(phase: .ended))
  }
}
