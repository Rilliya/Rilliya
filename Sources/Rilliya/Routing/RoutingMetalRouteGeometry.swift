import FlowingDayGraphLayout
import Foundation

enum RoutingMetalRouteGeometry {
  static let quadraticSubdivisionCount = 12
  static let cubicSubdivisionCount = 18

  static func points(for route: FlowingGraphEdgeRoute) -> [CGPoint] {
    var result = [route.start]
    var start = route.start
    for segment in route.segments {
      switch segment {
      case .line(let end):
        result.append(end)
        start = end
      case .quadratic(let control, let end):
        for step in 1...quadraticSubdivisionCount {
          let t = CGFloat(step) / CGFloat(quadraticSubdivisionCount)
          let inverse = 1 - t
          result.append(
            CGPoint(
              x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
              y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y
            )
          )
        }
        start = end
      case .cubic(let control1, let control2, let end):
        for step in 1...cubicSubdivisionCount {
          let t = CGFloat(step) / CGFloat(cubicSubdivisionCount)
          let inverse = 1 - t
          result.append(
            CGPoint(
              x: inverse * inverse * inverse * start.x
                + 3 * inverse * inverse * t * control1.x
                + 3 * inverse * t * t * control2.x + t * t * t * end.x,
              y: inverse * inverse * inverse * start.y
                + 3 * inverse * inverse * t * control1.y
                + 3 * inverse * t * t * control2.y + t * t * t * end.y
            )
          )
        }
        start = end
      }
    }
    return result
  }

  static func intersects(_ route: FlowingGraphEdgeRoute, rectangle: CGRect) -> Bool {
    let rectangle = rectangle.standardized
    guard !rectangle.isEmpty else { return false }
    let routePoints = points(for: route)
    return zip(routePoints, routePoints.dropFirst()).contains { start, end in
      segment(start, end, intersects: rectangle)
    }
  }

  private static func segment(
    _ start: CGPoint,
    _ end: CGPoint,
    intersects rectangle: CGRect
  ) -> Bool {
    if rectangle.contains(start) || rectangle.contains(end) { return true }
    let segmentBounds = CGRect(
      x: min(start.x, end.x),
      y: min(start.y, end.y),
      width: abs(end.x - start.x),
      height: abs(end.y - start.y)
    ).insetBy(dx: -0.5, dy: -0.5)
    guard segmentBounds.intersects(rectangle) else { return false }

    let topLeft = CGPoint(x: rectangle.minX, y: rectangle.minY)
    let topRight = CGPoint(x: rectangle.maxX, y: rectangle.minY)
    let bottomRight = CGPoint(x: rectangle.maxX, y: rectangle.maxY)
    let bottomLeft = CGPoint(x: rectangle.minX, y: rectangle.maxY)
    return segmentsIntersect(start, end, topLeft, topRight)
      || segmentsIntersect(start, end, topRight, bottomRight)
      || segmentsIntersect(start, end, bottomRight, bottomLeft)
      || segmentsIntersect(start, end, bottomLeft, topLeft)
  }

  private static func segmentsIntersect(
    _ firstStart: CGPoint,
    _ firstEnd: CGPoint,
    _ secondStart: CGPoint,
    _ secondEnd: CGPoint
  ) -> Bool {
    let firstA = cross(firstStart, firstEnd, secondStart)
    let firstB = cross(firstStart, firstEnd, secondEnd)
    let secondA = cross(secondStart, secondEnd, firstStart)
    let secondB = cross(secondStart, secondEnd, firstEnd)
    return firstA * firstB <= 0 && secondA * secondB <= 0
  }

  private static func cross(_ start: CGPoint, _ end: CGPoint, _ point: CGPoint) -> CGFloat {
    (end.x - start.x) * (point.y - start.y)
      - (end.y - start.y) * (point.x - start.x)
  }
}
