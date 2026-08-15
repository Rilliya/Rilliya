import FlowingDayControls
import SwiftUI

struct RoutingAccentPicker: View {
  let selection: RoutingAccentID?
  let inheritedAccentID: RoutingAccentID
  let inheritedLabel: String
  let setSelection: (RoutingAccentID?) -> Void

  var body: some View {
    FlowingMenu(
      selection?.displayName ?? inheritedLabel,
      systemImage: "paintpalette",
      minimumWidth: 150
    ) {
      Button {
        setSelection(nil)
      } label: {
        Label(inheritedLabel, systemImage: selection == nil ? "checkmark" : "arrow.uturn.backward")
      }

      Divider()

      ForEach(RoutingAccentID.families, id: \.name) { family in
        Menu(family.name) {
          ForEach(family.accents, id: \.self) { accentID in
            Button {
              setSelection(accentID)
            } label: {
              Label(
                accentID.displayName,
                systemImage: selection == accentID ? "checkmark.circle.fill" : "circle.fill"
              )
            }
          }
        }
      }
    }
    .flowingAccent((selection ?? inheritedAccentID).accent)
  }
}

struct RoutingAccentSwatch: View {
  let accentID: RoutingAccentID

  var body: some View {
    Circle()
      .fill(accentID.accent.fill)
      .overlay {
        Circle().strokeBorder(accentID.accent.foreground.opacity(0.24))
      }
      .frame(width: 18, height: 18)
      .accessibilityHidden(true)
  }
}
