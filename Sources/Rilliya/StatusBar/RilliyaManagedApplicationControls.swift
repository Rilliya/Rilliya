import Foundation
import Observation

struct RilliyaManagedApplication: Codable, Equatable, Identifiable, Sendable {
  static let maximumVolume = 4.0

  let id: UUID
  let sourceNodeID: UUID
  let gainNodeID: UUID
  let sourceToGainEdgeID: UUID
  let gainToOutputEdgeID: UUID
  var applicationURL: URL
  var bundleIdentifier: String?
  var displayName: String
  var volume: Double
  var isMuted: Bool

  init(application: InstalledApplication) {
    id = UUID()
    sourceNodeID = UUID()
    gainNodeID = UUID()
    sourceToGainEdgeID = UUID()
    gainToOutputEdgeID = UUID()
    applicationURL = canonicalApplicationURL(application.bundleURL)
    bundleIdentifier = application.bundleIdentifier
    displayName = application.displayName
    volume = 1
    isMuted = false
  }

  var volumePercentage: Int {
    Int((volume * 100).rounded())
  }

  var gainConfiguration: RoutingGainConfiguration {
    let effectiveVolume = min(max(volume, 0), Self.maximumVolume)
    let decibels =
      effectiveVolume > 0
      ? 20 * log10(effectiveVolume)
      : RoutingGainConfiguration.minimumGainDecibels
    return RoutingGainConfiguration(
      gainDecibels: min(
        max(decibels, RoutingGainConfiguration.minimumGainDecibels),
        RoutingGainConfiguration.maximumGainDecibels
      ),
      isMuted: isMuted || effectiveVolume == 0,
      isPolarityInverted: false
    )
  }

  func isValid() -> Bool {
    applicationURL.isFileURL
      && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && volume.isFinite
      && (0...Self.maximumVolume).contains(volume)
  }
}

@MainActor
@Observable
final class RilliyaManagedApplicationStore {
  nonisolated static let maximumApplicationCount = 64

  private(set) var applications: [RilliyaManagedApplication]

  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    applications = Self.decode(defaults.data(forKey: Keys.applications))
  }

  @discardableResult
  func add(_ application: InstalledApplication) -> UUID? {
    let canonicalURL = canonicalApplicationURL(application.bundleURL)
    guard applications.count < Self.maximumApplicationCount,
      !applications.contains(where: {
        canonicalApplicationURL($0.applicationURL) == canonicalURL
      })
    else { return nil }
    let managed = RilliyaManagedApplication(application: application)
    applications.append(managed)
    persist()
    return managed.id
  }

  func remove(id: UUID) {
    guard let index = applications.firstIndex(where: { $0.id == id }) else { return }
    applications.remove(at: index)
    persist()
  }

  func setVolume(_ volume: Double, id: UUID) {
    guard volume.isFinite,
      let index = applications.firstIndex(where: { $0.id == id })
    else { return }
    let normalized = min(max(volume, 0), RilliyaManagedApplication.maximumVolume)
    guard applications[index].volume != normalized else { return }
    applications[index].volume = normalized
    persist()
  }

  func setMuted(_ isMuted: Bool, id: UUID) {
    guard let index = applications.firstIndex(where: { $0.id == id }),
      applications[index].isMuted != isMuted
    else { return }
    applications[index].isMuted = isMuted
    persist()
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(applications) else { return }
    defaults.set(data, forKey: Keys.applications)
  }

  nonisolated private static func decode(_ data: Data?) -> [RilliyaManagedApplication] {
    guard let data,
      let decoded = try? JSONDecoder().decode([RilliyaManagedApplication].self, from: data)
    else { return [] }
    var ids = Set<UUID>()
    var sourceNodeIDs = Set<UUID>()
    var gainNodeIDs = Set<UUID>()
    var sourceEdgeIDs = Set<UUID>()
    var outputEdgeIDs = Set<UUID>()
    var applicationURLs = Set<URL>()
    var result: [RilliyaManagedApplication] = []
    result.reserveCapacity(min(decoded.count, maximumApplicationCount))
    for application in decoded {
      guard result.count < maximumApplicationCount else { break }
      guard application.isValid(),
        ids.insert(application.id).inserted,
        sourceNodeIDs.insert(application.sourceNodeID).inserted,
        gainNodeIDs.insert(application.gainNodeID).inserted,
        sourceEdgeIDs.insert(application.sourceToGainEdgeID).inserted,
        outputEdgeIDs.insert(application.gainToOutputEdgeID).inserted,
        applicationURLs.insert(canonicalApplicationURL(application.applicationURL)).inserted
      else { continue }
      result.append(application)
    }
    return result
  }

  private enum Keys {
    static let applications = "moe.uwucocoa.rilliya.managed-applications"
  }
}
