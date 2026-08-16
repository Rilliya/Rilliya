import Testing

@testable import Rilliya

@Suite("Rilliya status menu layout")
struct RilliyaStatusMenuLayoutTests {
  @Test
  func smallApplicationCollectionsUseTheirNaturalContentHeight() {
    #expect(!RilliyaStatusMenuLayout.usesScrollableApplicationList(for: 0))
    #expect(!RilliyaStatusMenuLayout.usesScrollableApplicationList(for: 1))
    #expect(!RilliyaStatusMenuLayout.usesScrollableApplicationList(for: 3))
    #expect(RilliyaStatusMenuLayout.usesScrollableApplicationList(for: 4))
  }
}
