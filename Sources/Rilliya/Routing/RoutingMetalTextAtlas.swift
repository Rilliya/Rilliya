import AppKit
import Metal

enum RoutingMetalAtlasTextureKind: UInt32 {
  case glyph
  case color
}

struct RoutingMetalAtlasEntry {
  let textureOrigin: SIMD2<Float>
  let textureSize: SIMD2<Float>
  let size: CGSize
  let textureKind: RoutingMetalAtlasTextureKind
}

@MainActor
final class RoutingMetalTextAtlas {
  private enum Key: Hashable {
    case text(String, CGFloat, CGFloat)
    case monospacedText(String, CGFloat, CGFloat)
    case symbol(String, CGFloat, CGFloat)
    case applicationIcon(URL, CGFloat, CGFloat)
  }

  private enum Constants {
    static let textureSize = 1_024
    static let rasterScale: CGFloat = 2
    static let padding = 2
  }

  static let nominalTextureMemoryByteCount =
    Constants.textureSize * Constants.textureSize
    + Constants.textureSize * Constants.textureSize * 4

  var cachedEntryCount: Int { entries.count }

  private let device: any MTLDevice

  private(set) var glyphTexture: any MTLTexture
  private(set) var colorTexture: any MTLTexture

  private var entries: [Key: RoutingMetalAtlasEntry] = [:]
  private var glyphAllocator = ShelfAllocator()
  private var colorAllocator = ShelfAllocator()
  private var resetBeforeNextFrame = false

  init(device: any MTLDevice) {
    self.device = device
    glyphTexture = Self.makeTexture(device: device, pixelFormat: .r8Unorm)
    colorTexture = Self.makeTexture(device: device, pixelFormat: .rgba8Unorm)
  }

  /// Applies a deferred reset only between complete frame-geometry builds.
  ///
  /// A full atlas never expands. The next frame uses new fixed-size textures and repopulates only
  /// visible content. Metal retains the previous textures for any command buffer that still uses
  /// them, so the CPU never overwrites regions while the GPU may be sampling them.
  func beginFrame() {
    guard resetBeforeNextFrame else { return }
    entries.removeAll(keepingCapacity: true)
    glyphAllocator = ShelfAllocator()
    colorAllocator = ShelfAllocator()
    glyphTexture = Self.makeTexture(device: device, pixelFormat: .r8Unorm)
    colorTexture = Self.makeTexture(device: device, pixelFormat: .rgba8Unorm)
    resetBeforeNextFrame = false
  }

  func text(
    _ value: String,
    size: CGFloat,
    weight: NSFont.Weight
  ) -> RoutingMetalAtlasEntry? {
    guard !value.isEmpty else { return nil }
    let key = Key.text(value, size, weight.rawValue)
    if let entry = entries[key] { return entry }
    let attributed = NSAttributedString(
      string: value,
      attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white,
      ]
    )
    return insertGlyph(key: key, attributed: attributed)
  }

  func monospacedText(
    _ value: String,
    size: CGFloat,
    weight: NSFont.Weight
  ) -> RoutingMetalAtlasEntry? {
    guard !value.isEmpty else { return nil }
    let key = Key.monospacedText(value, size, weight.rawValue)
    if let entry = entries[key] { return entry }
    let attributed = NSAttributedString(
      string: value,
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white,
      ]
    )
    return insertGlyph(key: key, attributed: attributed)
  }

  func symbol(
    _ name: String,
    pointSize: CGFloat,
    weight: NSFont.Weight
  ) -> RoutingMetalAtlasEntry? {
    let key = Key.symbol(name, pointSize, weight.rawValue)
    if let entry = entries[key] { return entry }
    guard
      let image = NSImage(
        systemSymbolName: name,
        accessibilityDescription: nil
      )?.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
      )
    else {
      return nil
    }
    return insertGlyph(key: key, size: image.size) { rect in
      image.draw(
        in: rect,
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: nil
      )
    }
  }

  func applicationIcon(
    at applicationURL: URL,
    size: CGSize
  ) -> RoutingMetalAtlasEntry? {
    let resolvedURL = applicationURL.resolvingSymlinksInPath().standardizedFileURL
    let key = Key.applicationIcon(resolvedURL, size.width, size.height)
    if let entry = entries[key] { return entry }
    let image = NSWorkspace.shared.icon(forFile: resolvedURL.path)
    return insertColor(key: key, size: size) { rect in
      image.draw(
        in: rect,
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high.rawValue]
      )
    }
  }

  private func insertGlyph(
    key: Key,
    attributed: NSAttributedString
  ) -> RoutingMetalAtlasEntry? {
    let measured = attributed.boundingRect(
      with: CGSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      ),
      options: [.usesFontLeading, .usesLineFragmentOrigin]
    ).integral.size
    return insertGlyph(key: key, size: measured) { rect in
      attributed.draw(at: rect.origin)
    }
  }

  private func insertGlyph(
    key: Key,
    size: CGSize,
    draw: (CGRect) -> Void
  ) -> RoutingMetalAtlasEntry? {
    let pixelSize = Self.pixelSize(for: size)
    guard
      let origin = glyphAllocator.allocate(
        width: pixelSize.width,
        height: pixelSize.height
      )
    else {
      resetBeforeNextFrame = true
      return nil
    }
    let pixels = rasterizeGlyph(
      size: size,
      pixelWidth: pixelSize.width,
      pixelHeight: pixelSize.height,
      draw: draw
    )
    replace(
      texture: glyphTexture,
      origin: origin,
      width: pixelSize.width,
      height: pixelSize.height,
      bytesPerPixel: 1,
      pixels: pixels
    )
    return storeEntry(
      key: key,
      origin: origin,
      pixelSize: pixelSize,
      logicalSize: size,
      textureKind: .glyph
    )
  }

  private func insertColor(
    key: Key,
    size: CGSize,
    draw: (CGRect) -> Void
  ) -> RoutingMetalAtlasEntry? {
    let pixelSize = Self.pixelSize(for: size)
    guard
      let origin = colorAllocator.allocate(
        width: pixelSize.width,
        height: pixelSize.height
      )
    else {
      resetBeforeNextFrame = true
      return nil
    }
    let pixels = rasterizeColor(
      size: size,
      pixelWidth: pixelSize.width,
      pixelHeight: pixelSize.height,
      draw: draw
    )
    replace(
      texture: colorTexture,
      origin: origin,
      width: pixelSize.width,
      height: pixelSize.height,
      bytesPerPixel: 4,
      pixels: pixels
    )
    return storeEntry(
      key: key,
      origin: origin,
      pixelSize: pixelSize,
      logicalSize: size,
      textureKind: .color
    )
  }

  private func storeEntry(
    key: Key,
    origin: MTLOrigin,
    pixelSize: (width: Int, height: Int),
    logicalSize: CGSize,
    textureKind: RoutingMetalAtlasTextureKind
  ) -> RoutingMetalAtlasEntry {
    let textureDimension = Float(Constants.textureSize)
    let entry = RoutingMetalAtlasEntry(
      textureOrigin: SIMD2(
        Float(origin.x) / textureDimension,
        Float(origin.y) / textureDimension
      ),
      textureSize: SIMD2(
        Float(pixelSize.width) / textureDimension,
        Float(pixelSize.height) / textureDimension
      ),
      size: logicalSize,
      textureKind: textureKind
    )
    entries[key] = entry
    return entry
  }

  private static func makeTexture(
    device: any MTLDevice,
    pixelFormat: MTLPixelFormat
  ) -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: pixelFormat,
      width: Constants.textureSize,
      height: Constants.textureSize,
      mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      preconditionFailure("Unable to allocate the routing Metal atlas")
    }
    return texture
  }

  private static func pixelSize(for size: CGSize) -> (width: Int, height: Int) {
    (
      max(Int(ceil(size.width * Constants.rasterScale)), 1),
      max(Int(ceil(size.height * Constants.rasterScale)), 1)
    )
  }

  private func rasterizeGlyph(
    size: CGSize,
    pixelWidth: Int,
    pixelHeight: Int,
    draw: (CGRect) -> Void
  ) -> [UInt8] {
    rasterize(
      size: size,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      bytesPerPixel: 1,
      colorSpace: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.none.rawValue,
      draw: draw
    )
  }

  private func rasterizeColor(
    size: CGSize,
    pixelWidth: Int,
    pixelHeight: Int,
    draw: (CGRect) -> Void
  ) -> [UInt8] {
    rasterize(
      size: size,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      bytesPerPixel: 4,
      colorSpace: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
      draw: draw
    )
  }

  private func rasterize(
    size: CGSize,
    pixelWidth: Int,
    pixelHeight: Int,
    bytesPerPixel: Int,
    colorSpace: CGColorSpace,
    bitmapInfo: UInt32,
    draw: (CGRect) -> Void
  ) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * bytesPerPixel)
    pixels.withUnsafeMutableBytes { bytes in
      guard
        let context = CGContext(
          data: bytes.baseAddress,
          width: pixelWidth,
          height: pixelHeight,
          bitsPerComponent: 8,
          bytesPerRow: pixelWidth * bytesPerPixel,
          space: colorSpace,
          bitmapInfo: bitmapInfo
        )
      else {
        return
      }
      context.scaleBy(x: Constants.rasterScale, y: Constants.rasterScale)
      let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = graphicsContext
      draw(CGRect(origin: .zero, size: size))
      NSGraphicsContext.restoreGraphicsState()
    }
    return pixels
  }

  private func replace(
    texture: any MTLTexture,
    origin: MTLOrigin,
    width: Int,
    height: Int,
    bytesPerPixel: Int,
    pixels: [UInt8]
  ) {
    pixels.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      texture.replace(
        region: MTLRegionMake2D(origin.x, origin.y, width, height),
        mipmapLevel: 0,
        withBytes: baseAddress,
        bytesPerRow: width * bytesPerPixel
      )
    }
  }

  private struct ShelfAllocator {
    private var cursorX = Constants.padding
    private var cursorY = Constants.padding
    private var rowHeight = 0

    mutating func allocate(width: Int, height: Int) -> MTLOrigin? {
      let paddedWidth = width + Constants.padding
      let paddedHeight = height + Constants.padding
      if cursorX + paddedWidth >= Constants.textureSize {
        cursorX = Constants.padding
        cursorY += rowHeight + Constants.padding
        rowHeight = 0
      }
      guard cursorY + paddedHeight < Constants.textureSize else { return nil }
      let origin = MTLOrigin(x: cursorX, y: cursorY, z: 0)
      cursorX += paddedWidth
      rowHeight = max(rowHeight, height)
      return origin
    }
  }
}
