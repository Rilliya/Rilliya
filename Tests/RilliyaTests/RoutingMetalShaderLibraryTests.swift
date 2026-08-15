import Metal
import Testing

@testable import Rilliya

struct RoutingMetalShaderLibraryTests {
  @Test @MainActor
  func buildTimeLibraryContainsEveryRequiredFunction() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let library = try RoutingMetalShaderLibrary.load(device: device)

    for functionName in RoutingMetalShaderLibrary.functionNames {
      #expect(library.makeFunction(name: functionName) != nil)
    }
  }
}
