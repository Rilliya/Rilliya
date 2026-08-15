struct WorkspaceState: Equatable {
  enum Phase: Equatable {
    case preparing
    case ready
  }

  private(set) var phase: Phase = .preparing

  var presentation: WorkspacePresentation {
    WorkspacePresentation(phase: phase)
  }

  mutating func completeLaunch() {
    phase = .ready
  }
}

struct WorkspacePresentation: Equatable {
  let title: String
  let detail: String
  let systemImage: String
  let status: String

  init(phase: WorkspaceState.Phase) {
    switch phase {
    case .preparing:
      title = "Preparing your workspace"
      detail = "Rilliya is getting ready."
      systemImage = "waveform"
      status = "Preparing"
    case .ready:
      title = "Let sound find its path"
      detail = "Audio sources and routing controls will appear here as the workspace comes alive."
      systemImage = "waveform.path"
      status = "Ready"
    }
  }
}
