import FlowingDayControls
import SwiftUI

enum RoutingAccentGridMetrics {
  static let chipLabelSize: CGFloat = 10.5
}

struct RoutingAccentGrid: View {
  let selection: RoutingAccentID?
  let inheritedAccentID: RoutingAccentID
  let inheritedLabel: String
  let setSelection: (RoutingAccentID?) -> Void

  @Environment(\.flowingTypography) private var typography

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 7)

  private var chipTypography: FlowingTypography {
    var result = typography
    result.selectionLabel = FlowingTextStyle(
      size: RoutingAccentGridMetrics.chipLabelSize,
      weight: .medium
    )
    return result
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        setSelection(nil)
      } label: {
        HStack(spacing: 9) {
          RoutingAccentSwatch(accentID: inheritedAccentID)
          VStack(alignment: .leading, spacing: 1) {
            Text(inheritedLabel)
              .font(.caption.weight(.semibold))
              .foregroundStyle(FlowingPalette.ink)
            Text(inheritedAccentID.displayName)
              .font(.caption2)
              .foregroundStyle(FlowingPalette.muted)
          }
          Spacer(minLength: 8)
          if selection == nil {
            Image(systemName: "checkmark")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(inheritedAccentID.accent.foreground)
          }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 38)
        .background(
          selection == nil ? inheritedAccentID.accent.veil : FlowingPalette.field,
          in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Use \(inheritedLabel), \(inheritedAccentID.displayName)")
      .accessibilityValue(selection == nil ? "Selected" : "Not selected")

      VStack(spacing: 7) {
        ForEach(Array(RoutingAccentID.families.enumerated()), id: \.offset) { _, family in
          LazyVGrid(columns: columns, spacing: 7) {
            ForEach(family.accents, id: \.self) { accentID in
              FlowingChip(accentID.displayName) {
                setSelection(accentID)
              }
              .flowingAccent(accentID.accent)
              .flowingTypography(chipTypography)
              .accessibilityValue(selection == accentID ? "Selected" : "Not selected")
            }
          }
          .accessibilityElement(children: .contain)
          .accessibilityLabel(family.name)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Color palette")
    }
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
