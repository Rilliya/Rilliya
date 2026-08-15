import FlowingDayControls
import SwiftUI

struct WorkspaceView: View {
  @State private var state = WorkspaceState()
  @State private var audioCatalog = AudioCatalogController()

  var body: some View {
    NavigationSplitView {
      AudioCatalogSidebar(state: audioCatalog.state) {
        audioCatalog.refresh()
      }
      .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
    } detail: {
      workspace
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: 760, minHeight: 500)
    .task {
      state.completeLaunch()
      audioCatalog.start()
    }
    .onDisappear {
      audioCatalog.stop()
    }
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
