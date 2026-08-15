import CoreGraphics
import Foundation
import Testing

@testable import Rilliya

@Suite("Routing node accents")
struct RoutingNodeAccentTests {
  @Test
  func paletteExposesEveryFlowingDayAccentExactlyOnce() {
    #expect(RoutingAccentID.allCases.count == 49)
    #expect(Set(RoutingAccentID.allCases.map(\.rawValue)).count == 49)
    #expect(Set(RoutingAccentID.allCases.map(\.baseRGB)).count == 49)
    #expect(RoutingAccentID.families.flatMap(\.accents) == RoutingAccentID.allCases)
  }

  @Test
  func resolverUsesNodeThenTypeThenBuiltInPrecedence() {
    #expect(
      RoutingNodeAccentResolver.resolve(
        nodeOverride: .fuchsia,
        typeOverride: .mint,
        kind: .visualizer
      ) == .fuchsia
    )
    #expect(
      RoutingNodeAccentResolver.resolve(
        nodeOverride: nil,
        typeOverride: .mint,
        kind: .visualizer
      ) == .mint
    )
    #expect(
      RoutingNodeAccentResolver.resolve(
        nodeOverride: nil,
        typeOverride: nil,
        kind: .visualizer
      ) == .seafoam
    )
  }

  @Test @MainActor
  func workspaceStoresANodeSpecificOverrideWithoutChangingItsKind() throws {
    let workspace = RoutingWorkspaceModel()
    let nodeID = workspace.addDelayNode(centeredAt: CGPoint(x: 100, y: 100))
    let beforeRevision = workspace.persistenceRevision

    workspace.setAccentOverride(.iris, for: nodeID)

    let node = try #require(workspace.node(id: nodeID))
    #expect(node.value.kind == .delay)
    #expect(node.accentOverride == .iris)
    #expect(workspace.persistenceRevision == beforeRevision + 1)
  }

  @Test
  func nodeOverrideRoundTripsThroughWorkflowPersistence() throws {
    let original = RoutingWorkspaceNode(
      id: UUID(),
      value: .peakLevel,
      frame: CGRect(x: 10, y: 20, width: 252, height: 128),
      accentOverride: .bloom
    )

    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(RoutingWorkspaceNode.self, from: data)

    #expect(restored == original)
    #expect(restored.accentOverride == .bloom)
  }
}
