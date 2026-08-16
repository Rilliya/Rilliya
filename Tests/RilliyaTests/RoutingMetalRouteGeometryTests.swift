import FlowingDayGraphLayout
import Foundation
import Testing

@testable import Rilliya

struct RoutingMetalRouteGeometryTests {
  @Test
  func marqueeSelectsAConnectionThatCrossesItWithoutContainingAnEndpoint() {
    let route = FlowingGraphEdgeRoute(
      start: CGPoint(x: 0, y: 20),
      segments: [.line(end: CGPoint(x: 200, y: 20))]
    )

    #expect(
      RoutingMetalRouteGeometry.intersects(
        route,
        rectangle: CGRect(x: 90, y: 10, width: 20, height: 20)
      )
    )
    #expect(
      !RoutingMetalRouteGeometry.intersects(
        route,
        rectangle: CGRect(x: 90, y: 40, width: 20, height: 20)
      )
    )
  }

  @Test
  func marqueeTestsCurvedRoutesUsingTheSharedRenderSubdivision() {
    let route = FlowingGraphEdgeRoute(
      start: CGPoint(x: 0, y: 0),
      segments: [
        .cubic(
          control1: CGPoint(x: 50, y: 120),
          control2: CGPoint(x: 150, y: 120),
          end: CGPoint(x: 200, y: 0)
        )
      ]
    )

    let points = RoutingMetalRouteGeometry.points(for: route)

    #expect(points.count == RoutingMetalRouteGeometry.cubicSubdivisionCount + 1)
    #expect(
      RoutingMetalRouteGeometry.intersects(
        route,
        rectangle: CGRect(x: 90, y: 85, width: 20, height: 20)
      )
    )
  }
}
