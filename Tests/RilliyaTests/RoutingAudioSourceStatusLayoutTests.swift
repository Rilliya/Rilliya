import CoreGraphics
import Testing

@testable import Rilliya

struct RoutingAudioSourceStatusLayoutTests {
  @Test
  func inputLabelGutterKeepsStatusClearOfThePort() {
    let nodeFrame = CGRect(x: 100, y: 200, width: 252, height: 128)

    let status = RoutingAudioSourceStatusLayout.frame(
      in: nodeFrame,
      hasInputPort: true,
      hasOutputPort: false
    )

    #expect(status.minX == nodeFrame.minX + 42)
    #expect(status.maxX == nodeFrame.maxX - 14)
  }

  @Test
  func twoSidedNodeReservesBothPortLabelGutters() {
    let nodeFrame = CGRect(x: -50, y: 20, width: 252, height: 128)

    let status = RoutingAudioSourceStatusLayout.frame(
      in: nodeFrame,
      hasInputPort: true,
      hasOutputPort: true
    )

    #expect(status.minX == nodeFrame.minX + 42)
    #expect(status.maxX == nodeFrame.maxX - 42)
  }
}
