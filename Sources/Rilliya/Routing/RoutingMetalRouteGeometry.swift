import FlowingDayGraphLayout
import Foundation

enum RoutingMetalRouteGeometry {
  private struct Quadratic {
    let start: CGPoint
    let control: CGPoint
    let end: CGPoint

    func split() -> (Quadratic, Quadratic) {
      let startControl = start.midpoint(to: control)
      let controlEnd = control.midpoint(to: end)
      let midpoint = startControl.midpoint(to: controlEnd)
      return (
        Quadratic(start: start, control: startControl, end: midpoint),
        Quadratic(start: midpoint, control: controlEnd, end: end)
      )
    }
  }

  private struct Cubic {
    let start: CGPoint
    let control1: CGPoint
    let control2: CGPoint
    let end: CGPoint

    func split() -> (Cubic, Cubic) {
      let a = start.midpoint(to: control1)
      let b = control1.midpoint(to: control2)
      let c = control2.midpoint(to: end)
      let d = a.midpoint(to: b)
      let e = b.midpoint(to: c)
      let midpoint = d.midpoint(to: e)
      return (
        Cubic(start: start, control1: a, control2: d, end: midpoint),
        Cubic(start: midpoint, control1: e, control2: c, end: end)
      )
    }
  }

  private static let maximumSubdivisionDepth = 10
  private static let minimumScale: CGFloat = 0.001

  static func points(
    for route: FlowingGraphEdgeRoute,
    scale: CGFloat = 1,
    maximumPixelError: CGFloat = 0.3
  ) -> [CGPoint] {
    let maximumWorldError = maximumPixelError / max(scale, minimumScale)
    var result = [route.start]
    var start = route.start
    for segment in route.segments {
      switch segment {
      case .line(let end):
        result.append(end)
        start = end
      case .quadratic(let control, let end):
        appendPoints(
          for: Quadratic(start: start, control: control, end: end),
          tolerance: maximumWorldError,
          to: &result
        )
        start = end
      case .cubic(let control1, let control2, let end):
        appendPoints(
          for: Cubic(start: start, control1: control1, control2: control2, end: end),
          tolerance: maximumWorldError,
          to: &result
        )
        start = end
      }
    }
    return result
  }

  private static func appendPoints(
    for quadratic: Quadratic,
    tolerance: CGFloat,
    to points: inout [CGPoint]
  ) {
    var stack = [(quadratic, 0)]
    while let (segment, depth) = stack.popLast() {
      if depth == maximumSubdivisionDepth
        || segment.control.distance(toSegmentFrom: segment.start, to: segment.end) <= tolerance
      {
        points.append(segment.end)
        continue
      }
      let (left, right) = segment.split()
      stack.append((right, depth + 1))
      stack.append((left, depth + 1))
    }
  }

  private static func appendPoints(
    for cubic: Cubic,
    tolerance: CGFloat,
    to points: inout [CGPoint]
  ) {
    var stack = [(cubic, 0)]
    while let (segment, depth) = stack.popLast() {
      if depth == maximumSubdivisionDepth
        || (segment.control1.distance(toSegmentFrom: segment.start, to: segment.end) <= tolerance
          && segment.control2.distance(toSegmentFrom: segment.start, to: segment.end) <= tolerance)
      {
        points.append(segment.end)
        continue
      }
      let (left, right) = segment.split()
      stack.append((right, depth + 1))
      stack.append((left, depth + 1))
    }
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

struct RoutingMetalStrokeTriangle: Equatable {
  let point0: CGPoint
  let point1: CGPoint
  let point2: CGPoint
}

enum RoutingMetalStrokeTessellator {
  private static let minimumLength: CGFloat = 0.0001

  static func triangles(
    for points: [CGPoint],
    width: CGFloat,
    miterLimit: CGFloat = 2
  ) -> [RoutingMetalStrokeTriangle] {
    let points = removingDuplicateNeighbors(from: points)
    guard points.count > 1, width > 0 else { return [] }
    let directions = (1..<points.count).map { index in
      normalizedVector(from: points[index - 1], to: points[index])
    }
    let halfWidth = width / 2
    var offsets: [CGVector] = []
    offsets.reserveCapacity(points.count)

    for index in points.indices {
      if index == points.startIndex {
        offsets.append(directions[0].normal.scaled(by: halfWidth))
      } else if index == points.index(before: points.endIndex) {
        offsets.append(
          directions[directions.index(before: directions.endIndex)].normal.scaled(by: halfWidth))
      } else {
        offsets.append(
          miterOffset(
            previous: directions[index - 1],
            next: directions[index],
            halfWidth: halfWidth,
            limit: miterLimit
          )
        )
      }
    }

    var triangles: [RoutingMetalStrokeTriangle] = []
    triangles.reserveCapacity((points.count - 1) * 2)
    for index in 1..<points.count {
      let previousLeft = points[index - 1].offset(by: offsets[index - 1])
      let previousRight = points[index - 1].offset(by: offsets[index - 1].scaled(by: -1))
      let left = points[index].offset(by: offsets[index])
      let right = points[index].offset(by: offsets[index].scaled(by: -1))
      triangles.append(
        RoutingMetalStrokeTriangle(
          point0: previousLeft,
          point1: previousRight,
          point2: left
        )
      )
      triangles.append(
        RoutingMetalStrokeTriangle(
          point0: previousRight,
          point1: right,
          point2: left
        )
      )
    }
    return triangles
  }

  private static func removingDuplicateNeighbors(from points: [CGPoint]) -> [CGPoint] {
    var result: [CGPoint] = []
    result.reserveCapacity(points.count)
    for point in points where result.last.map({ $0.distance(to: point) > minimumLength }) ?? true {
      result.append(point)
    }
    return result
  }

  private static func normalizedVector(from start: CGPoint, to end: CGPoint) -> CGVector {
    let vector = CGVector(dx: end.x - start.x, dy: end.y - start.y)
    let length = max(hypot(vector.dx, vector.dy), minimumLength)
    return CGVector(dx: vector.dx / length, dy: vector.dy / length)
  }

  private static func miterOffset(
    previous: CGVector,
    next: CGVector,
    halfWidth: CGFloat,
    limit: CGFloat
  ) -> CGVector {
    let tangent = CGVector(dx: previous.dx + next.dx, dy: previous.dy + next.dy)
    let tangentLength = hypot(tangent.dx, tangent.dy)
    guard tangentLength > minimumLength else {
      return next.normal.scaled(by: halfWidth)
    }
    var miter = CGVector(
      dx: -tangent.dy / tangentLength,
      dy: tangent.dx / tangentLength
    )
    let nextNormal = next.normal
    if miter.dot(nextNormal) < 0 {
      miter = miter.scaled(by: -1)
    }
    let denominator = max(miter.dot(nextNormal), minimumLength)
    let length = min(halfWidth / denominator, halfWidth * limit)
    return miter.scaled(by: length)
  }
}

extension CGPoint {
  fileprivate func squaredDistance(to other: CGPoint) -> CGFloat {
    let dx = x - other.x
    let dy = y - other.y
    return dx * dx + dy * dy
  }

  fileprivate func distance(to other: CGPoint) -> CGFloat {
    sqrt(squaredDistance(to: other))
  }

  fileprivate func midpoint(to other: CGPoint) -> CGPoint {
    CGPoint(x: (x + other.x) / 2, y: (y + other.y) / 2)
  }

  fileprivate func offset(by vector: CGVector) -> CGPoint {
    CGPoint(x: x + vector.dx, y: y + vector.dy)
  }

  fileprivate func distance(toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return sqrt(squaredDistance(to: start)) }
    let projection = ((x - start.x) * dx + (y - start.y) * dy) / lengthSquared
    let progress = min(max(projection, 0), 1)
    let closest = CGPoint(x: start.x + dx * progress, y: start.y + dy * progress)
    return sqrt(squaredDistance(to: closest))
  }
}

extension CGVector {
  fileprivate var normal: CGVector {
    CGVector(dx: -dy, dy: dx)
  }

  fileprivate func dot(_ other: CGVector) -> CGFloat {
    dx * other.dx + dy * other.dy
  }

  fileprivate func scaled(by scale: CGFloat) -> CGVector {
    CGVector(dx: dx * scale, dy: dy * scale)
  }
}
