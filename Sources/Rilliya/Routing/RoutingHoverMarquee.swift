import Foundation
import SwiftUI

enum RoutingHoverMarquee {
  static let startDelay: TimeInterval = 1
  static let endpointPause: TimeInterval = 0.7
  static let pointsPerSecond: CGFloat = 32

  static func offset(
    contentWidth: CGFloat,
    viewportWidth: CGFloat,
    elapsed: TimeInterval
  ) -> CGFloat {
    let overflow = max(contentWidth - viewportWidth, 0)
    guard overflow > 0, elapsed > 0 else { return 0 }
    let travelDuration = TimeInterval(overflow / pointsPerSecond)
    let cycleDuration = travelDuration * 2 + endpointPause * 2
    var phase = elapsed.truncatingRemainder(dividingBy: cycleDuration)
    if phase < travelDuration {
      return overflow * CGFloat(phase / travelDuration)
    }
    phase -= travelDuration
    if phase < endpointPause { return overflow }
    phase -= endpointPause
    if phase < travelDuration {
      return overflow * (1 - CGFloat(phase / travelDuration))
    }
    return 0
  }
}

struct RoutingHorizontalTextureSlice: Equatable {
  let originX: CGFloat
  let width: CGFloat
  let textureOriginX: Float
  let textureWidth: Float
}

enum RoutingHorizontalTextureClip {
  static func slice(
    originX: CGFloat,
    width: CGFloat,
    textureOriginX: Float,
    textureWidth: Float,
    lowerBound: CGFloat,
    upperBound: CGFloat
  ) -> RoutingHorizontalTextureSlice? {
    guard width > 0, upperBound > lowerBound else { return nil }
    let visibleMinimum = max(originX, lowerBound)
    let visibleMaximum = min(originX + width, upperBound)
    guard visibleMaximum > visibleMinimum else { return nil }
    let lowerFraction = Float((visibleMinimum - originX) / width)
    let visibleFraction = Float((visibleMaximum - visibleMinimum) / width)
    return RoutingHorizontalTextureSlice(
      originX: visibleMinimum,
      width: visibleMaximum - visibleMinimum,
      textureOriginX: textureOriginX + textureWidth * lowerFraction,
      textureWidth: textureWidth * visibleFraction
    )
  }
}

struct RoutingHoverMarqueeText: View {
  let text: String
  let font: Font
  let color: Color
  let lineHeight: CGFloat

  @State private var contentWidth: CGFloat = 0
  @State private var isHovering = false
  @State private var marqueeStartedAt: Date?

  var body: some View {
    GeometryReader { geometry in
      TimelineView(
        .animation(
          minimumInterval: 1 / 60,
          paused: marqueeStartedAt == nil || contentWidth <= geometry.size.width
        )
      ) { context in
        Text(text)
          .font(font)
          .foregroundStyle(color)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
          .offset(
            x: -RoutingHoverMarquee.offset(
              contentWidth: contentWidth,
              viewportWidth: geometry.size.width,
              elapsed: marqueeStartedAt.map { context.date.timeIntervalSince($0) } ?? 0
            )
          )
          .background {
            GeometryReader { contentGeometry in
              Color.clear.preference(
                key: RoutingMarqueeTextWidthPreferenceKey.self,
                value: contentGeometry.size.width
              )
            }
          }
      }
    }
    .frame(height: lineHeight)
    .clipped()
    .contentShape(Rectangle())
    .onPreferenceChange(RoutingMarqueeTextWidthPreferenceKey.self) { contentWidth = $0 }
    .onHover { isHovering = $0 }
    .task(id: isHovering) {
      marqueeStartedAt = nil
      guard isHovering else { return }
      try? await Task.sleep(for: .seconds(RoutingHoverMarquee.startDelay))
      guard !Task.isCancelled, isHovering else { return }
      marqueeStartedAt = .now
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
  }
}

private struct RoutingMarqueeTextWidthPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}
