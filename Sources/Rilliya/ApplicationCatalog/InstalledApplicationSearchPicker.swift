import AppKit
import FlowingDayControls
import SwiftUI

enum InstalledApplicationPickerFilter {
  static func items(
    _ items: [InstalledApplicationCatalogItem],
    matching query: String
  ) -> [InstalledApplicationCatalogItem] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return items }
    return items.filter {
      $0.application.displayName.localizedCaseInsensitiveContains(query)
        || ($0.application.bundleIdentifier?.localizedCaseInsensitiveContains(query) == true)
    }
  }
}

struct InstalledApplicationSearchPicker: View {
  @Environment(\.flowingAccent) private var accent
  @FocusState private var isSearchFocused: Bool
  @State private var query = ""

  let items: [InstalledApplicationCatalogItem]
  @Binding var selection: String
  let iconResolver: NSWorkspaceInstalledApplicationIconResolver
  let maximumVisibleOptions: Int

  init(
    items: [InstalledApplicationCatalogItem],
    selection: Binding<String>,
    iconResolver: NSWorkspaceInstalledApplicationIconResolver,
    maximumVisibleOptions: Int = 8
  ) {
    self.items = items
    _selection = selection
    self.iconResolver = iconResolver
    self.maximumVisibleOptions = max(maximumVisibleOptions, 1)
  }

  private var filteredItems: [InstalledApplicationCatalogItem] {
    InstalledApplicationPickerFilter.items(items, matching: query)
  }

  private var includesEmptySelection: Bool {
    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || "No Application".localizedCaseInsensitiveContains(query)
  }

  private var visibleOptionCount: Int {
    filteredItems.count + (includesEmptySelection ? 1 : 0)
  }

  var body: some View {
    VStack(spacing: 8) {
      FlowingTextField(
        "Installed Applications",
        text: $query,
        placeholder: "Search",
        systemImage: "magnifyingglass",
        emphasis: .accented
      )
      .focused($isSearchFocused)

      optionList
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Installed Applications")
  }

  @ViewBuilder
  private var optionList: some View {
    if visibleOptionCount == 0 {
      Text("No Results")
        .font(.callout)
        .foregroundStyle(FlowingPalette.faint)
        .frame(maxWidth: .infinity, minHeight: 38)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 4) {
            if includesEmptySelection {
              emptySelectionButton
                .id("")
            }
            ForEach(filteredItems, id: \.application.id) { item in
              optionButton(item)
                .id(item.application.bundleURL.absoluteString)
            }
          }
        }
        .scrollIndicators(.automatic)
        .frame(height: CGFloat(min(visibleOptionCount, maximumVisibleOptions)) * 38)
        .onAppear {
          proxy.scrollTo(selection, anchor: .center)
        }
      }
    }
  }

  private var emptySelectionButton: some View {
    optionButton(
      id: "",
      label: "No Application",
      isRunning: false
    ) {
      Image(systemName: "nosign")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(FlowingPalette.muted)
        .frame(width: 22, height: 22)
        .background(FlowingPalette.field, in: RoundedRectangle(cornerRadius: 6))
    }
  }

  private func optionButton(_ item: InstalledApplicationCatalogItem) -> some View {
    let application = item.application
    return optionButton(
      id: application.bundleURL.absoluteString,
      label: application.displayName,
      isRunning: item.isRunning
    ) {
      DeferredInstalledApplicationIcon(
        application: application,
        iconResolver: iconResolver
      )
    }
  }

  private func optionButton<Leading: View>(
    id: String,
    label: String,
    isRunning: Bool,
    @ViewBuilder leading: () -> Leading
  ) -> some View {
    let isSelected = id == selection
    return Button {
      isSearchFocused = false
      selection = id
      query = ""
    } label: {
      HStack(spacing: 9) {
        leading()

        Text(label)
          .font(.callout.weight(.medium))
          .foregroundStyle(isSelected ? accent.foreground : FlowingPalette.ink)
          .lineLimit(1)

        Spacer(minLength: 6)

        if isRunning {
          Circle()
            .fill(Color(nsColor: .systemGreen))
            .frame(width: 7, height: 7)
            .accessibilityLabel("Running")
        }

        if isSelected {
          Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(accent.foreground)
            .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 10)
      .frame(height: 34)
      .background(
        isSelected ? accent.wash : Color.clear,
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(isSelected ? "Selected" : "Not Selected")
  }
}

struct DeferredInstalledApplicationIcon: View {
  let application: InstalledApplication
  let iconResolver: NSWorkspaceInstalledApplicationIconResolver
  let size: CGFloat
  let cornerRadius: CGFloat

  @State private var icon: NSImage?

  init(
    application: InstalledApplication,
    iconResolver: NSWorkspaceInstalledApplicationIconResolver,
    size: CGFloat = 22,
    cornerRadius: CGFloat = 6
  ) {
    self.application = application
    self.iconResolver = iconResolver
    self.size = size
    self.cornerRadius = cornerRadius
  }

  var body: some View {
    Group {
      if let icon {
        Image(nsImage: icon)
          .resizable()
          .scaledToFit()
      } else {
        ZStack {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(FlowingPalette.field)
          Image(systemName: "app.dashed")
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(FlowingPalette.faint)
        }
      }
    }
    .frame(width: size, height: size)
    .task(id: application.bundleURL) {
      if let cachedIcon = iconResolver.cachedIcon(for: application) {
        icon = cachedIcon
      } else {
        icon = await iconResolver.loadIcon(for: application)
      }
    }
    .onDisappear {
      icon = nil
    }
    .accessibilityHidden(true)
  }
}
