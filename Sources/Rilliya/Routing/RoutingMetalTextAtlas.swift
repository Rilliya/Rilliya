import AppKit
import Metal

struct RoutingMetalAtlasEntry {
  let textureOrigin: SIMD2<Float>
  let textureSize: SIMD2<Float>
  let size: CGSize
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
    static let textureSize = 4_096
    static let rasterScale: CGFloat = 4
    static let padding = 4
  }

  let texture: any MTLTexture

  private var entries: [Key: RoutingMetalAtlasEntry] = [:]
  private var cursorX = Constants.padding
  private var cursorY = Constants.padding
  private var rowHeight = 0

  init(device: any MTLDevice) {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: Constants.textureSize,
      height: Constants.textureSize,
      mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead]
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      preconditionFailure("Unable to allocate the routing text atlas")
    }
    self.texture = texture
    clearTexture()
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
    let measured = attributed.boundingRect(
      with: CGSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      ),
      options: [.usesFontLeading, .usesLineFragmentOrigin]
    ).integral.size
    return insert(key: key, size: measured) { rect in
      attributed.draw(at: rect.origin)
    }
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
    let measured = attributed.boundingRect(
      with: CGSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      ),
      options: [.usesFontLeading, .usesLineFragmentOrigin]
    ).integral.size
    return insert(key: key, size: measured) { rect in
      attributed.draw(at: rect.origin)
    }
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
    return insert(key: key, size: image.size) { rect in
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
    return insert(key: key, size: size) { rect in
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

  private func insert(
    key: Key,
    size: CGSize,
    draw: (CGRect) -> Void
  ) -> RoutingMetalAtlasEntry? {
    let pixelWidth = max(Int(ceil(size.width * Constants.rasterScale)), 1)
    let pixelHeight = max(Int(ceil(size.height * Constants.rasterScale)), 1)
    guard let origin = allocate(width: pixelWidth, height: pixelHeight) else { return nil }
    let pixels = rasterize(
      size: size,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      draw: draw
    )
    pixels.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      texture.replace(
        region: MTLRegionMake2D(origin.x, origin.y, pixelWidth, pixelHeight),
        mipmapLevel: 0,
        withBytes: baseAddress,
        bytesPerRow: pixelWidth * 4
      )
    }
    let textureDimension = Float(Constants.textureSize)
    let entry = RoutingMetalAtlasEntry(
      textureOrigin: SIMD2(
        Float(origin.x) / textureDimension,
        Float(origin.y) / textureDimension
      ),
      textureSize: SIMD2(
        Float(pixelWidth) / textureDimension,
        Float(pixelHeight) / textureDimension
      ),
      size: size
    )
    entries[key] = entry
    return entry
  }

  private func allocate(width: Int, height: Int) -> MTLOrigin? {
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

  private func rasterize(
    size: CGSize,
    pixelWidth: Int,
    pixelHeight: Int,
    draw: (CGRect) -> Void
  ) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
    pixels.withUnsafeMutableBytes { bytes in
      guard
        let context = CGContext(
          data: bytes.baseAddress,
          width: pixelWidth,
          height: pixelHeight,
          bitsPerComponent: 8,
          bytesPerRow: pixelWidth * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
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

  private func clearTexture() {
    let bytes = [UInt8](
      repeating: 0,
      count: Constants.textureSize * Constants.textureSize * 4
    )
    bytes.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      texture.replace(
        region: MTLRegionMake2D(0, 0, Constants.textureSize, Constants.textureSize),
        mipmapLevel: 0,
        withBytes: baseAddress,
        bytesPerRow: Constants.textureSize * 4
      )
    }
  }
}
