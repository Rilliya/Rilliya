import Foundation
import Testing

struct RilliyaAppIconTests {
  @Test
  func iconComposerDefinesDefaultDarkAndMonochromeAppearances() throws {
    let packageURL =
      repositoryURL
      .appendingPathComponent("Sources/Rilliya/Resources/AppIcon.icon")
    let manifestData = try Data(contentsOf: packageURL.appendingPathComponent("icon.json"))
    let manifest = try #require(
      JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    )

    let supportedPlatforms = try #require(
      manifest["supported-platforms"] as? [String: Any]
    )
    #expect(supportedPlatforms["squares"] as? [String] == ["macOS"])

    let fills = try #require(manifest["fill-specializations"] as? [[String: Any]])
    #expect(
      Set(fills.map { ($0["appearance"] as? String) ?? "default" }) == [
        "default", "dark", "tinted",
      ])
    for fill in fills {
      let value = try #require(fill["value"] as? [String: Any])
      let colors = try #require(value["linear-gradient"] as? [String])
      #expect(colors.count == 2)
      if (fill["appearance"] as? String) != "tinted" {
        #expect(colors[0] == colors[1])
      }
    }

    let groups = try #require(manifest["groups"] as? [[String: Any]])
    let layers = try #require(groups.first?["layers"] as? [[String: Any]])
    let variants = try #require(
      layers.first?["image-name-specializations"] as? [[String: Any]]
    )
    let filenames = try Dictionary(
      uniqueKeysWithValues: variants.map { variant in
        (
          (variant["appearance"] as? String) ?? "default",
          try #require(variant["value"] as? String)
        )
      })

    #expect(filenames["default"] == "RilliyaMark.svg")
    #expect(filenames["dark"] == "RilliyaMark-Dark.svg")
    #expect(filenames["tinted"] == "RilliyaMark-Mono.svg")

    let assetsURL = packageURL.appendingPathComponent("Assets")
    for filename in filenames.values {
      let artworkURL = assetsURL.appendingPathComponent(filename)
      #expect(FileManager.default.fileExists(atPath: artworkURL.path))
      let artwork = try String(contentsOf: artworkURL, encoding: .utf8)
      #expect(artwork.contains("viewBox=\"0 0 1024 1024\""))
    }
  }

  @Test
  func lightAndDarkAppearancesPreserveCanonicalBrandArtwork() throws {
    let assetsURL =
      repositoryURL
      .appendingPathComponent("Sources/Rilliya/Resources/AppIcon.icon/Assets")
    let defaultArtwork = try String(
      contentsOf: assetsURL.appendingPathComponent("RilliyaMark.svg"),
      encoding: .utf8
    )
    let darkArtwork = try String(
      contentsOf: assetsURL.appendingPathComponent("RilliyaMark-Dark.svg"),
      encoding: .utf8
    )

    #expect(defaultArtwork == darkArtwork)
    for canonicalColor in ["#3DCE87", "#5DD9B6", "#42C851", "#B7E46A"] {
      #expect(defaultArtwork.contains(canonicalColor))
    }
    #expect(defaultArtwork.contains("fill-opacity=\"0.84\""))
    #expect(!defaultArtwork.contains("<rect"))
    #expect(!defaultArtwork.contains("<filter"))
  }

  @Test
  func finalBrandAssetsContainSelectedFlatBackgrounds() throws {
    let assetsURL = repositoryURL.appendingPathComponent("assets/app-icon")
    let lightArtwork = try String(
      contentsOf: assetsURL.appendingPathComponent("RilliyaAppIcon-Light.svg"),
      encoding: .utf8
    )
    let darkArtwork = try String(
      contentsOf: assetsURL.appendingPathComponent("RilliyaAppIcon-Dark.svg"),
      encoding: .utf8
    )
    let monoArtwork = try String(
      contentsOf: assetsURL.appendingPathComponent("RilliyaAppIcon-Mono.svg"),
      encoding: .utf8
    )

    #expect(lightArtwork.contains("fill=\"#FAFCFA\""))
    #expect(darkArtwork.contains("fill=\"#164A40\""))
    #expect(monoArtwork.contains("fill=\"#DDE2DF\""))
    #expect(monoArtwork.contains("fill-opacity=\"0.42\""))
    #expect(monoArtwork.contains("fill=\"#FFFFFF\" fill-opacity=\"0.18\""))
    #expect(monoArtwork.contains("fill=\"#FFFFFF\" fill-opacity=\"0.10\""))
    #expect(!lightArtwork.contains("id=\"tile\""))
    #expect(!darkArtwork.contains("id=\"tile\""))
  }

  private var repositoryURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
