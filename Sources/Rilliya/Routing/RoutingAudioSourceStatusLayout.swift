import CoreGraphics

enum RoutingAudioSourceStatusLayout {
  private static let edgeInset: CGFloat = 14
  private static let portLabelInset: CGFloat = 42

  static func frame(
    in nodeFrame: CGRect,
    hasInputPort: Bool,
    hasOutputPort: Bool
  ) -> CGRect {
    let leading = hasInputPort ? portLabelInset : edgeInset
    let trailing = hasOutputPort ? portLabelInset : edgeInset
    return CGRect(
      x: nodeFrame.minX + leading,
      y: nodeFrame.maxY - 44,
      width: max(0, nodeFrame.width - leading - trailing),
      height: 30
    )
  }
}
