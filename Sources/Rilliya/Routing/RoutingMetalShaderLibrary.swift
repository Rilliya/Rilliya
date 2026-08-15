import Foundation
import Metal

enum RoutingMetalShaderLibrary {
  static let functionNames = [
    "gridVertex",
    "gridFragment",
    "shapeVertex",
    "shapeFragment",
    "triangleVertex",
    "flatFragment",
    "atlasVertex",
    "atlasFragment",
  ]

  static func load(
    device: any MTLDevice,
    bundle: Bundle = .main
  ) throws -> any MTLLibrary {
    let library = try device.makeDefaultLibrary(bundle: bundle)
    for functionName in functionNames {
      guard library.makeFunction(name: functionName) != nil else {
        throw RoutingMetalShaderLibraryError.missingFunction(functionName)
      }
    }
    return library
  }
}

enum RoutingMetalShaderLibraryError: Error, Equatable {
  case missingFunction(String)
}
