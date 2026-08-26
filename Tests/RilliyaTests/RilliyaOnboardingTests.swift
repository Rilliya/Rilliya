import Foundation
import Testing

@testable import Rilliya

struct RilliyaOnboardingTests {
  @Test @MainActor
  func previewAppearsAfterRestorationWithoutPersistingDismissal() throws {
    let defaults = try makeDefaults()
    let coordinator = RilliyaOnboardingCoordinator(
      defaults: defaults,
      arguments: ["Rilliya", "--onboarding-preview"]
    )

    coordinator.workflowRestorationDidFinish(.restored)
    #expect(coordinator.step == .welcome)

    coordinator.begin()
    coordinator.toggle(.routeInput)
    coordinator.toggle(.recordApplication)
    #expect(coordinator.step == .capabilityModel)
    #expect(coordinator.selectedGoals == [.routeInput, .recordApplication])

    coordinator.dismiss()
    #expect(!coordinator.isPresented)
    #expect(RilliyaOnboardingStateStore(defaults: defaults).load() == .absent)
  }

  @Test @MainActor
  func goalsCanBeSelectedIndependentlyAndDeselected() throws {
    let coordinator = RilliyaOnboardingCoordinator(
      defaults: try makeDefaults(),
      arguments: ["Rilliya", "--onboarding-preview"]
    )

    coordinator.toggle(.listenToApplication)
    coordinator.toggle(.routeInput)
    coordinator.toggle(.listenToApplication)

    #expect(coordinator.selectedGoals == [.routeInput])
  }

  @Test @MainActor
  func backNavigationReturnsToThePreviousStep() throws {
    let coordinator = RilliyaOnboardingCoordinator(
      defaults: try makeDefaults(),
      arguments: ["Rilliya", "--onboarding-preview"]
    )

    coordinator.begin()
    #expect(coordinator.step == .capabilityModel)

    coordinator.goBack()
    #expect(coordinator.step == .welcome)
  }

  @Test @MainActor
  func virtualAudioEducationReturnsToGoalSelection() throws {
    let coordinator = RilliyaOnboardingCoordinator(
      defaults: try makeDefaults(),
      arguments: ["Rilliya", "--onboarding-preview"]
    )

    coordinator.begin()
    coordinator.learnAboutVirtualAudio()
    #expect(coordinator.step == .virtualAudio)

    coordinator.goBack()
    #expect(coordinator.step == .capabilityModel)
  }

  @Test @MainActor
  func successfulCreationCompletesOnboardingOnlyAfterTheWorkFinishes() async throws {
    let defaults = try makeDefaults()
    let coordinator = RilliyaOnboardingCoordinator(
      defaults: defaults,
      arguments: ["Rilliya"],
      automaticPresentationEnabled: true
    )
    coordinator.workflowRestorationDidFinish(.noDocument)
    coordinator.begin()
    coordinator.toggle(.listenToApplication)
    coordinator.learnAboutVirtualAudio()
    var receivedGoals: [RilliyaOnboardingGoal] = []

    await coordinator.completeOnboarding { goals in
      receivedGoals = goals
    }

    #expect(receivedGoals == [.listenToApplication])
    #expect(!coordinator.isPresented)
    let record = try #require(loadedRecord(from: defaults))
    #expect(record.status == .completed)
    #expect(record.selectedGoals == [.listenToApplication])
  }

  @Test @MainActor
  func failedCreationKeepsTheSelectionAndOnboardingOpen() async throws {
    let defaults = try makeDefaults()
    let coordinator = RilliyaOnboardingCoordinator(
      defaults: defaults,
      arguments: ["Rilliya"],
      automaticPresentationEnabled: true
    )
    coordinator.workflowRestorationDidFinish(.noDocument)
    coordinator.begin()
    coordinator.toggle(.recordApplication)
    coordinator.learnAboutVirtualAudio()

    await coordinator.completeOnboarding { _ in
      throw RilliyaOnboardingTemplateError.workflowChanged
    }

    #expect(coordinator.isPresented)
    #expect(coordinator.selectedGoals == [.recordApplication])
    #expect(
      coordinator.creationIssue
        == RilliyaOnboardingTemplateError.workflowChanged.localizedDescription)
    #expect(loadedRecord(from: defaults)?.status == .inProgress)
  }

  @Test @MainActor
  func completingWithoutASelectionKeepsTheDefaultWorkflow() async throws {
    let defaults = try makeDefaults()
    let coordinator = RilliyaOnboardingCoordinator(
      defaults: defaults,
      arguments: ["Rilliya"],
      automaticPresentationEnabled: true
    )
    coordinator.workflowRestorationDidFinish(.noDocument)
    coordinator.begin()
    coordinator.learnAboutVirtualAudio()
    var attemptedCreation = false

    await coordinator.completeOnboarding { _ in
      attemptedCreation = true
    }

    #expect(!attemptedCreation)
    #expect(!coordinator.isPresented)
    #expect(loadedRecord(from: defaults)?.status == .completed)
  }

  @Test @MainActor
  func automaticPresentationRequiresConfirmedMissingDocument() throws {
    let defaults = try makeDefaults()
    let coordinator = RilliyaOnboardingCoordinator(
      defaults: defaults,
      arguments: ["Rilliya"],
      automaticPresentationEnabled: true
    )

    coordinator.workflowRestorationDidFinish(.noDocument)

    #expect(coordinator.step == .welcome)
  }

  @Test @MainActor
  func restoredAndFailedDocumentsSuppressAutomaticPresentation() throws {
    let defaults = try makeDefaults()
    for outcome in [
      RilliyaWorkflowRestorationOutcome.restored,
      .recoveredFromBackup,
      .failed,
    ] {
      let coordinator = RilliyaOnboardingCoordinator(
        defaults: defaults,
        arguments: ["Rilliya"],
        automaticPresentationEnabled: true
      )
      coordinator.workflowRestorationDidFinish(outcome)
      #expect(!coordinator.isPresented)
    }
  }

  @Test @MainActor
  func dismissedStateSuppressesLaterAutomaticPresentation() throws {
    let defaults = try makeDefaults()
    let first = RilliyaOnboardingCoordinator(
      defaults: defaults,
      arguments: ["Rilliya"],
      automaticPresentationEnabled: true
    )
    first.workflowRestorationDidFinish(.noDocument)
    first.dismiss()

    let restored = RilliyaOnboardingCoordinator(
      defaults: defaults,
      arguments: ["Rilliya"],
      automaticPresentationEnabled: true
    )
    restored.workflowRestorationDidFinish(.noDocument)

    #expect(!restored.isPresented)
  }

  @Test @MainActor
  func goalSelectionCanBeSkippedBeforeVirtualAudioEducation() throws {
    let defaults = try makeDefaults()
    let coordinator = RilliyaOnboardingCoordinator(
      defaults: defaults,
      arguments: ["Rilliya"],
      automaticPresentationEnabled: true
    )
    coordinator.workflowRestorationDidFinish(.noDocument)
    coordinator.begin()

    coordinator.learnAboutVirtualAudio()

    #expect(coordinator.isPresented)
    #expect(coordinator.step == .virtualAudio)
    let record = try #require(loadedRecord(from: defaults))
    #expect(record.status == .inProgress)
    #expect(record.step == .virtualAudio)
    #expect(record.selectedGoals.isEmpty)
  }

  @Test
  func corruptStateFailsClosed() throws {
    let defaults = try makeDefaults()
    defaults.set(Data("not-json".utf8), forKey: "onboarding.state")

    #expect(RilliyaOnboardingStateStore(defaults: defaults).load() == .invalid)
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "moe.uwucocoa.rilliya.onboarding-tests.\(UUID().uuidString)"
    return try #require(UserDefaults(suiteName: suiteName))
  }

  private func loadedRecord(from defaults: UserDefaults) -> RilliyaOnboardingRecord? {
    guard case .loaded(let record) = RilliyaOnboardingStateStore(defaults: defaults).load()
    else { return nil }
    return record
  }
}
