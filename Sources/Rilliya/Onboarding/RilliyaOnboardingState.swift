import Foundation
import Observation

enum RilliyaWorkflowRestorationOutcome: Equatable, Sendable {
  case noDocument
  case restored
  case recoveredFromBackup
  case failed
}

enum RilliyaOnboardingStep: String, Codable, Equatable, Sendable {
  case welcome
  case capabilityModel
  case virtualAudio
}

enum RilliyaOnboardingGoal: String, CaseIterable, Codable, Hashable, Sendable {
  case listenToApplication
  case routeInput
  case recordApplication
}

struct RilliyaOnboardingRecord: Codable, Equatable, Sendable {
  enum Status: String, Codable, Equatable, Sendable {
    case inProgress
    case completed
    case dismissed
  }

  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let status: Status
  let step: RilliyaOnboardingStep
  let selectedGoals: [RilliyaOnboardingGoal]

  init(
    status: Status,
    step: RilliyaOnboardingStep,
    selectedGoals: [RilliyaOnboardingGoal] = []
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.status = status
    self.step = step
    self.selectedGoals = selectedGoals
  }
}

struct RilliyaOnboardingStateStore {
  enum LoadResult: Equatable {
    case absent
    case loaded(RilliyaOnboardingRecord)
    case invalid
  }

  private static let key = "onboarding.state"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> LoadResult {
    guard let data = defaults.data(forKey: Self.key) else { return .absent }
    guard
      let record = try? JSONDecoder().decode(RilliyaOnboardingRecord.self, from: data),
      record.schemaVersion == RilliyaOnboardingRecord.currentSchemaVersion
    else { return .invalid }
    return .loaded(record)
  }

  func save(_ record: RilliyaOnboardingRecord) {
    guard let data = try? JSONEncoder().encode(record) else { return }
    defaults.set(data, forKey: Self.key)
  }
}

@MainActor
@Observable
final class RilliyaOnboardingCoordinator {
  private(set) var step: RilliyaOnboardingStep?
  private(set) var selectedGoals: [RilliyaOnboardingGoal] = []
  private(set) var restorationOutcome: RilliyaWorkflowRestorationOutcome?
  private(set) var creationIssue: String?
  private(set) var isCreatingWorkflows = false

  let isDesignPreview: Bool

  @ObservationIgnored private let stateStore: RilliyaOnboardingStateStore
  @ObservationIgnored private let automaticPresentationEnabled: Bool

  init(
    defaults: UserDefaults = .standard,
    arguments: [String] = ProcessInfo.processInfo.arguments,
    automaticPresentationEnabled: Bool = true
  ) {
    stateStore = RilliyaOnboardingStateStore(defaults: defaults)
    self.automaticPresentationEnabled = automaticPresentationEnabled
    isDesignPreview = arguments.contains("--onboarding-preview")
  }

  var isPresented: Bool { step != nil }

  func workflowRestorationDidFinish(_ outcome: RilliyaWorkflowRestorationOutcome) {
    restorationOutcome = outcome
    if isDesignPreview {
      step = .welcome
      return
    }
    guard automaticPresentationEnabled, outcome == .noDocument else { return }
    switch stateStore.load() {
    case .absent:
      step = .welcome
    case .loaded(let record) where record.status == .inProgress:
      step = record.step
      selectedGoals = record.selectedGoals
    case .loaded, .invalid:
      break
    }
  }

  func begin() {
    transition(to: .capabilityModel)
  }

  func goBack() {
    switch step {
    case .virtualAudio:
      transition(to: .capabilityModel)
    case .capabilityModel:
      transition(to: .welcome)
    case .welcome, nil:
      break
    }
  }

  func learnAboutVirtualAudio() {
    transition(to: .virtualAudio)
  }

  func toggle(_ goal: RilliyaOnboardingGoal) {
    if let index = selectedGoals.firstIndex(of: goal) {
      selectedGoals.remove(at: index)
    } else {
      selectedGoals.append(goal)
    }
    persistInProgress()
  }

  func completeOnboarding(
    using create: @MainActor ([RilliyaOnboardingGoal]) async throws -> Void
  ) async {
    guard !isCreatingWorkflows else { return }
    guard !selectedGoals.isEmpty else {
      complete()
      return
    }
    isCreatingWorkflows = true
    creationIssue = nil
    do {
      try await create(selectedGoals)
      complete()
    } catch {
      creationIssue = error.localizedDescription
    }
    isCreatingWorkflows = false
  }

  func dismiss() {
    guard !isDesignPreview else {
      step = nil
      return
    }
    stateStore.save(
      RilliyaOnboardingRecord(
        status: .dismissed,
        step: step ?? .welcome,
        selectedGoals: selectedGoals
      )
    )
    step = nil
  }

  private func transition(to step: RilliyaOnboardingStep) {
    self.step = step
    persistInProgress()
  }

  private func complete() {
    if !isDesignPreview {
      stateStore.save(
        RilliyaOnboardingRecord(
          status: .completed,
          step: step ?? .capabilityModel,
          selectedGoals: selectedGoals
        )
      )
    }
    step = nil
  }

  private func persistInProgress() {
    guard !isDesignPreview, let step else { return }
    stateStore.save(
      RilliyaOnboardingRecord(
        status: .inProgress,
        step: step,
        selectedGoals: selectedGoals
      )
    )
  }
}
