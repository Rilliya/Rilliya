import CoreGraphics
import FlowingDayGraphCanvas
import FlowingDayGraphComposition
import FlowingDayGraphCore
import Foundation

struct RoutingApplicationSelection: Equatable, Hashable, Identifiable, Sendable {
  let id: String
  let applicationURL: URL
  let bundleIdentifier: String?
  let displayName: String

  init(
    stableID: String,
    applicationURL: URL,
    bundleIdentifier: String?,
    displayName: String
  ) {
    precondition(!stableID.isEmpty)
    precondition(!displayName.isEmpty)
    id = stableID
    self.applicationURL = applicationURL
    self.bundleIdentifier = bundleIdentifier
    self.displayName = displayName
  }
}

enum RoutingNodeValue: Equatable, Sendable {
  case applicationAudio(selection: RoutingApplicationSelection?)

  var applicationSelection: RoutingApplicationSelection? {
    switch self {
    case .applicationAudio(let selection):
      return selection
    }
  }
}

struct RoutingWorkspaceNode: Equatable, Identifiable, Sendable {
  let id: UUID
  var value: RoutingNodeValue
  var frame: CGRect
}

enum RoutingGraphPortValue: Equatable, Sendable {
  case audio
}

enum RoutingGraphEdgeValue: Equatable, Sendable {
  case audio
}

enum RoutingGraphSchema: FlowingGraphSchema {
  typealias NodeID = UUID
  typealias NodeValue = RoutingNodeValue
  typealias PortID = UUID
  typealias PortValue = RoutingGraphPortValue
  typealias EdgeID = UUID
  typealias EdgeValue = RoutingGraphEdgeValue
}

enum RoutingCanvasSchema: FlowingGraphCanvasSchema {
  typealias DocumentID = String
  typealias GraphID = String
  typealias EntryPointID = String
  typealias LinkID = String
  typealias LinkValue = String
  typealias GraphSchema = RoutingGraphSchema
}

typealias RoutingCanvasContent = FlowingGraphCanvasContent<RoutingCanvasSchema>
typealias RoutingCanvasElementID = FlowingGraphCompositionElementID<RoutingCanvasSchema>
typealias RoutingCanvasAccessibilitySnapshot =
  FlowingGraphCanvasAccessibilitySnapshot<RoutingCanvasElementID>

enum RoutingCanvasMetrics {
  static let nodeSize = CGSize(width: 252, height: 128)
  static let contentBounds = CGRect(
    x: -100_000,
    y: -100_000,
    width: 200_000,
    height: 200_000
  )
}

enum RoutingNodeInsertion {
  static func point(
    in visibleWorldRect: CGRect,
    existingNodeCount: Int
  ) -> CGPoint {
    precondition(existingNodeCount >= 0)
    let center =
      visibleWorldRect.isEmpty
      ? CGPoint.zero
      : CGPoint(x: visibleWorldRect.midX, y: visibleWorldRect.midY)
    let offset = CGFloat(existingNodeCount % 6) * 28
    return CGPoint(x: center.x + offset, y: center.y + offset)
  }
}
