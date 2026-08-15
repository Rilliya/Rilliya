#if PROFILE
  import Foundation

  @MainActor
  struct RoutingProfilingScenario {
    let nodePairCount: Int

    static func fromProcessArguments(
      _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> RoutingProfilingScenario? {
      guard
        let optionIndex = arguments.firstIndex(of: "--routing-profile-node-pairs"),
        arguments.indices.contains(optionIndex + 1),
        let count = Int(arguments[optionIndex + 1]),
        (1...2_000).contains(count)
      else {
        return nil
      }
      return RoutingProfilingScenario(nodePairCount: count)
    }

    func makeWorkflowLibrary() -> RoutingWorkflowLibrary {
      let workspace = RoutingWorkspaceModel()
      var nodes: [RoutingWorkspaceNode] = []
      var edges: [RoutingWorkspaceEdge] = []
      nodes.reserveCapacity(nodePairCount * 2)
      edges.reserveCapacity(nodePairCount)

      let columns = max(Int(Double(nodePairCount).squareRoot().rounded(.up)), 1)
      for index in 0..<nodePairCount {
        let column = index % columns
        let row = index / columns
        let origin = CGPoint(x: CGFloat(column) * 720, y: CGFloat(row) * 260)
        let sourceID = UUID()
        let targetID = UUID()
        nodes.append(
          RoutingWorkspaceNode(
            id: sourceID,
            value: .applicationAudio(selection: nil, channelPresentation: .aggregate),
            frame: CGRect(origin: origin, size: RoutingCanvasMetrics.baseNodeSize)
          )
        )
        nodes.append(
          RoutingWorkspaceNode(
            id: targetID,
            value: .visualizer(configuration: .initial),
            frame: CGRect(
              x: origin.x + 340,
              y: origin.y,
              width: RoutingCanvasMetrics.baseNodeSize.width,
              height: RoutingCanvasMetrics.baseNodeSize.height
            )
          )
        )
        edges.append(
          RoutingWorkspaceEdge(
            id: UUID(),
            source: RoutingWorkspacePortAddress(
              nodeID: sourceID,
              portID: RoutingGraphPortID(direction: .output, channel: .all)
            ),
            target: RoutingWorkspacePortAddress(
              nodeID: targetID,
              portID: RoutingGraphPortID(direction: .input, channel: .all)
            )
          )
        )
      }

      workspace.installProfilingGraph(nodes: nodes, edges: edges)
      let workflow = RoutingWorkflowModel(name: "Profile", workspace: workspace)
      return RoutingWorkflowLibrary(workflows: [workflow])
    }
  }
#endif
