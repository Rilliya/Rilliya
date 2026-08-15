import FlowingDayControls
import SwiftUI

struct WorkspaceView: View {
  @State private var state = WorkspaceState()

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
    } detail: {
      workspace
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: 760, minHeight: 500)
    .task {
      state.completeLaunch()
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Rilliya")
          .font(.system(size: 24, weight: .semibold, design: .rounded))
        FlowingBadge(
          state.presentation.status,
          systemImage: "sparkles",
          tone: .accent
        )
      }

      FlowingSection(
        "Sources",
        footer: "Applications and audio devices will remain distinct sources."
      ) {
        Label("No sources loaded", systemImage: "waveform.badge.plus")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Spacer(minLength: 0)
    }
    .padding(20)
  }

  private var workspace: some View {
    ZStack {
      FlowingPalette.canvas
        .ignoresSafeArea()

      FlowingCard(
        alignment: .center,
        spacing: 12,
        contentInsets: EdgeInsets(top: 32, leading: 36, bottom: 32, trailing: 36)
      ) {
        FlowingEmptyState(systemImage: state.presentation.systemImage) {
          VStack(spacing: 7) {
            Text(state.presentation.title)
              .font(.title3.weight(.semibold))
              .foregroundStyle(FlowingPalette.ink)
            Text(state.presentation.detail)
              .multilineTextAlignment(.center)
          }
        }
      }
      .frame(maxWidth: 460)
      .padding(40)
    }
  }
}

#Preview {
  WorkspaceView()
    .frame(width: 1_080, height: 680)
}
