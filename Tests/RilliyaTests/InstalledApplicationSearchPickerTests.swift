import Foundation
import Testing

@testable import Rilliya

struct InstalledApplicationSearchPickerTests {
  @Test
  func filterMatchesDisplayNameAndBundleIdentifier() {
    let music = item(name: "Music", bundleIdentifier: "com.apple.Music")
    let recorder = item(name: "Field Recorder", bundleIdentifier: "org.example.recorder")
    let items = [music, recorder]

    #expect(InstalledApplicationPickerFilter.items(items, matching: "music") == [music])
    #expect(InstalledApplicationPickerFilter.items(items, matching: "EXAMPLE") == [recorder])
    #expect(InstalledApplicationPickerFilter.items(items, matching: "  ") == items)
  }

  private func item(
    name: String,
    bundleIdentifier: String
  ) -> InstalledApplicationCatalogItem {
    let url = URL(fileURLWithPath: "/Applications/\(name).app")
    let application = InstalledApplication(
      id: InstalledApplicationID(
        fileResourceIdentifier: Data(name.utf8),
        canonicalURL: url
      ),
      bundleURL: url,
      bundleIdentifier: bundleIdentifier,
      displayName: name,
      kind: .regular,
      discoverySources: [.standardApplicationDirectory]
    )
    return InstalledApplicationCatalogItem(
      application: application,
      runningApplications: []
    )
  }
}
