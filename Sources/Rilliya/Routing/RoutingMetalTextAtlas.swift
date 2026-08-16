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
    /// Six samples per point retain native Retina detail through the supported 3× canvas zoom.
    static let glyphRasterScale: CGFloat = 6
    static let glyphTextureSize = 4_096

    /// Application icons never need the graph's high-resolution monochrome glyph budget.
    static let colorRasterScale: CGFloat = 2
    static let colorTextureSize = 1_024
    static let atlasPadding = 3
  }

  static let nominalTextureMemoryByteCount =
    Constants.glyphTextureSize * Constants.glyphTextureSize
    + Constants.colorTextureSize * Constants.colorTextureSize * 4

  var cachedEntryCount: Int { entries.count }

  private let device: any MTLDevice

  private(set) var glyphTexture: any MTLTexture
  private(set) var colorTexture: any MTLTexture

  private var entries: [Key: RoutingMetalAtlasEntry] = [:]
  private var glyphAllocator = ShelfAllocator(textureSize: Constants.glyphTextureSize)
  private var colorAllocator = ShelfAllocator(textureSize: Constants.colorTextureSize)
  private var resetBeforeNextFrame = false

  init(device: any MTLDevice) {
    self.device = device
    glyphTexture = Self.makeTexture(
      device: device,
      pixelFormat: .r8Unorm,
      textureSize: Constants.glyphTextureSize
    )
    colorTexture = Self.makeTexture(
      device: device,
      pixelFormat: .rgba8Unorm,
      textureSize: Constants.colorTextureSize
    )
  }

  /// Applies a deferred reset only between complete frame-geometry builds.
  ///
  /// A full atlas never expands. The next frame uses new fixed-size textures and repopulates only
  /// visible content. Metal retains the previous textures for any command buffer that still uses
  /// them, so the CPU never overwrites regions while the GPU may be sampling them.
  func beginFrame() {
    guard resetBeforeNextFrame else { return }
    entries.removeAll(keepingCapacity: true)
    glyphAllocator = ShelfAllocator(textureSize: Constants.glyphTextureSize)
    colorAllocator = ShelfAllocator(textureSize: Constants.colorTextureSize)
    glyphTexture = Self.makeTexture(
      device: device,
      pixelFormat: .r8Unorm,
      textureSize: Constants.glyphTextureSize
    )
    colorTexture = Self.makeTexture(
      device: device,
      pixelFormat: .rgba8Unorm,
      textureSize: Constants.colorTextureSize
    )
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
    _ image: NSImage,
    applicationURL: URL,
    size: CGSize
  ) -> RoutingMetalAtlasEntry? {
    let resolvedURL = applicationURL.resolvingSymlinksInPath().standardizedFileURL
    let key = Key.applicationIcon(resolvedURL, size.width, size.height)
    if let entry = entries[key] { return entry }
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
    let pixelSize = Self.pixelSize(for: size, rasterScale: Constants.glyphRasterScale)
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
      rasterScale: Constants.glyphRasterScale,
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
      textureKind: .glyph,
      textureSize: Constants.glyphTextureSize
    )
  }

  private func insertColor(
    key: Key,
    size: CGSize,
    draw: (CGRect) -> Void
  ) -> RoutingMetalAtlasEntry? {
    let pixelSize = Self.pixelSize(for: size, rasterScale: Constants.colorRasterScale)
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
      rasterScale: Constants.colorRasterScale,
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
      textureKind: .color,
      textureSize: Constants.colorTextureSize
    )
  }

  private func storeEntry(
    key: Key,
    origin: MTLOrigin,
    pixelSize: (width: Int, height: Int),
    logicalSize: CGSize,
    textureKind: RoutingMetalAtlasTextureKind,
    textureSize: Int
  ) -> RoutingMetalAtlasEntry {
    let textureDimension = Float(textureSize)
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
    pixelFormat: MTLPixelFormat,
    textureSize: Int
  ) -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: pixelFormat,
      width: textureSize,
      height: textureSize,
      mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead]
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      preconditionFailure("Unable to allocate the routing Metal atlas")
    }
    return texture
  }

  private static func pixelSize(
    for size: CGSize,
    rasterScale: CGFloat
  ) -> (width: Int, height: Int) {
    (
      max(Int(ceil(size.width * rasterScale)), 1),
      max(Int(ceil(size.height * rasterScale)), 1)
    )
  }

  private func rasterizeGlyph(
    size: CGSize,
    pixelWidth: Int,
    pixelHeight: Int,
    rasterScale: CGFloat,
    draw: (CGRect) -> Void
  ) -> [UInt8] {
    let rgba = rasterize(
      size: size,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      rasterScale: rasterScale,
      bytesPerPixel: 4,
      colorSpace: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
      draw: draw
    )

    // SF Symbols are template images and may rasterize as black. Their coverage lives in the
    // alpha channel, so using grayscale intensity as the mask makes valid symbols disappear.
    // Extracting alpha also gives text and symbols the same antialiased coverage semantics.
    var alpha = [UInt8](repeating: 0, count: pixelWidth * pixelHeight)
    for index in alpha.indices {
      alpha[index] = rgba[index * 4 + 3]
    }
    return alpha
  }

  private func rasterizeColor(
    size: CGSize,
    pixelWidth: Int,
    pixelHeight: Int,
    rasterScale: CGFloat,
    draw: (CGRect) -> Void
  ) -> [UInt8] {
    rasterize(
      size: size,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      rasterScale: rasterScale,
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
    rasterScale: CGFloat,
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
      context.scaleBy(x: rasterScale, y: rasterScale)
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
    let textureSize: Int
    private var cursorX = Constants.atlasPadding
    private var cursorY = Constants.atlasPadding
    private var rowHeight = 0

    mutating func allocate(width: Int, height: Int) -> MTLOrigin? {
      let paddedWidth = width + Constants.atlasPadding
      let paddedHeight = height + Constants.atlasPadding
      if cursorX + paddedWidth >= textureSize {
        cursorX = Constants.atlasPadding
        cursorY += rowHeight + Constants.atlasPadding
        rowHeight = 0
      }
      guard cursorY + paddedHeight < textureSize else { return nil }
      let origin = MTLOrigin(x: cursorX, y: cursorY, z: 0)
      cursorX += paddedWidth
      rowHeight = max(rowHeight, height)
      return origin
    }
  }
}
