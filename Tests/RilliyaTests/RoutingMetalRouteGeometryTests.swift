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

    #expect(points.first == route.start)
    #expect(points.last == CGPoint(x: 200, y: 0))
    #expect(
      RoutingMetalRouteGeometry.intersects(
        route,
        rectangle: CGRect(x: 90, y: 85, width: 20, height: 20)
      )
    )
  }

  @Test
  func curveSubdivisionTracksScreenScale() {
    let route = FlowingGraphEdgeRoute(
      start: CGPoint(x: 0, y: 0),
      segments: [
        .cubic(
          control1: CGPoint(x: 0, y: 400),
          control2: CGPoint(x: 400, y: 400),
          end: CGPoint(x: 400, y: 0)
        )
      ]
    )

    let normalScale = RoutingMetalRouteGeometry.points(for: route, scale: 1)
    let magnified = RoutingMetalRouteGeometry.points(for: route, scale: 4)

    #expect(magnified.count > normalScale.count)
    #expect(normalScale.count > 19)
  }

  @Test
  func strokeTrianglesShareVerticesAtPolylineJoints() {
    let triangles = RoutingMetalStrokeTessellator.triangles(
      for: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)],
      width: 2
    )

    #expect(triangles.count == 4)
    #expect(triangles[0].point2 == triangles[2].point0)
    #expect(triangles[1].point1 == triangles[2].point1)
  }

  @Test
  func edgeStrokeMatchesPortaWidthAndScaling() {
    #expect(RoutingMetalEdgeStrokeMetrics.preferredSampleCount == 4)
    #expect(
      RoutingMetalEdgeStrokeMetrics.worldWidth(isEmphasized: false, zoom: 1) == 1.35
    )
    #expect(
      RoutingMetalEdgeStrokeMetrics.worldWidth(isEmphasized: true, zoom: 1) == 2.2
    )
    #expect(
      RoutingMetalEdgeStrokeMetrics.worldWidth(isEmphasized: false, zoom: 2) * 2 == 2.7
    )
    #expect(
      RoutingMetalEdgeStrokeMetrics.worldWidth(isEmphasized: false, zoom: 0.25) * 0.25
        == 0.75
    )
  }
}
