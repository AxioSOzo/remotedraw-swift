// Chrome that is not a control: the pill, the pin and the aura.
//
// Ported from `apps/ios/RemoteDraw/DrawingBoardView.swift`, where all three
// lived as `private` types inside the 4,200-line board.
#if canImport(UIKit) && !os(watchOS)
import SwiftUI

/// Non-blocking "snap to shape" offer, shown after a mid-confidence stroke
/// commits.
///
/// Tapping replaces the committed freehand ink with the recognised primitive;
/// drawing again simply dismisses it. It never blocks input, which is the whole
/// reason it is a pill floating over the board rather than a dialog: a
/// suggestion that stops you drawing has cost more than it offered.
public struct RemoteDrawShapeSnapPill: View {
  let onTap: () -> Void

  @Environment(\.remoteDrawAppearance) private var appearance
  @Environment(\.remoteDrawStrings) private var strings

  public init(onTap: @escaping () -> Void) {
    self.onTap = onTap
  }

  public var body: some View {
    Button(action: onTap) {
      HStack(spacing: 7) {
        Image(systemName: "wand.and.stars")
          .font(.system(size: 14, weight: .semibold))
        Text(strings.snapToShape)
          .font(.system(size: 14, weight: .semibold))
      }
      .foregroundStyle(appearance.ink)
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .background(.regularMaterial, in: Capsule())
      .overlay(
        Capsule().stroke(Color.black.opacity(0.12), lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Snap stroke to recognised shape")
  }
}

/// The marker shown at a text insertion point while the composer is open.
public struct RemoteDrawTextPlacementPin: View {
  @Environment(\.remoteDrawAppearance) private var appearance

  public init() {}

  public var body: some View {
    Image(systemName: "mappin.circle.fill")
      .font(.system(size: 42, weight: .bold))
      .symbolRenderingMode(.palette)
      .foregroundStyle(appearance.ink, .white)
      .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
      .accessibilityHidden(true)
  }
}

/// The aura around the screen edge while ink is live.
///
/// Deliberately edge-anchored rather than attached to the stroke: it says "this
/// is being sent" without putting anything near the mark, and it is the one
/// piece of chrome that is legible while a hand covers the phone.
public struct RemoteDrawLiveInkGlow: View {
  let isActive: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulse = false
  @State private var morph = false

  public init(isActive: Bool) {
    self.isActive = isActive
  }

  public var body: some View {
    GeometryReader { proxy in
      let metrics = glowMetrics(for: proxy)

      ZStack {
        screenshotEdgeFill(metrics: metrics)

        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
          .stroke(
            auraGradient,
            style: StrokeStyle(lineWidth: metrics.edgeWidth, lineCap: .round, lineJoin: .round)
          )
          .blur(radius: metrics.blurRadius)
          .opacity(isActive ? (pulse ? 0.7 : 0.56) : 0)
          .padding(metrics.inset)
      }
      .saturation(pulse ? 1.12 : 0.96)
      .hueRotation(.degrees(morph ? 7 : -5))
      .frame(width: metrics.size.width, height: metrics.size.height)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(.easeOut(duration: 0.14), value: isActive)
    .onAppear(perform: updateAnimation)
    .onChange(of: isActive) { _, _ in updateAnimation() }
    .onChange(of: reduceMotion) { _, _ in updateAnimation() }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func screenshotEdgeFill(metrics: EdgeGlowMetrics) -> some View {
    Rectangle()
      .fill(auraGradient)
      .mask {
        Rectangle()
          .strokeBorder(lineWidth: metrics.screenshotFillWidth)
          .blur(radius: metrics.blurRadius * 0.9)
      }
      .blur(radius: metrics.blurRadius * 0.8)
      .opacity(isActive ? (pulse ? 0.2 : 0.15) : 0)
      .frame(width: metrics.size.width, height: metrics.size.height)
  }

  private var auraGradient: AngularGradient {
    AngularGradient(
      gradient: Gradient(stops: [
        .init(color: .glowSky.opacity(0.9), location: 0.00),
        .init(color: .glowCyan.opacity(0.82), location: 0.10),
        .init(color: .glowMint.opacity(0.84), location: 0.21),
        .init(color: .glowLime.opacity(0.78), location: 0.34),
        .init(color: .glowGold.opacity(0.82), location: 0.47),
        .init(color: .glowRose.opacity(0.78), location: 0.60),
        .init(color: .glowPink.opacity(0.82), location: 0.73),
        .init(color: .glowViolet.opacity(0.78), location: 0.86),
        .init(color: .glowSky.opacity(0.9), location: 1.00),
      ]),
      center: .center,
      startAngle: morph ? .degrees(202) : .degrees(216),
      endAngle: morph ? .degrees(562) : .degrees(576)
    )
  }

  private func glowMetrics(for proxy: GeometryProxy) -> EdgeGlowMetrics {
    let size = proxy.size
    let minDimension = min(size.width, size.height)
    let largestSafeInset = max(
      proxy.safeAreaInsets.top,
      proxy.safeAreaInsets.leading,
      proxy.safeAreaInsets.bottom,
      proxy.safeAreaInsets.trailing
    )
    let edgeWidth = max(10, min(13, minDimension * 0.026))
    let blurRadius = edgeWidth * 0.5
    let inset = max(edgeWidth * 0.44, 5)
    let screenshotFillWidth = inset + blurRadius + 4
    let screenCornerRadius = min(
      max(minDimension * 0.145, largestSafeInset + 8, 50),
      minDimension * 0.22
    )

    return EdgeGlowMetrics(
      size: size,
      edgeWidth: edgeWidth,
      blurRadius: blurRadius,
      inset: inset,
      screenshotFillWidth: screenshotFillWidth,
      cornerRadius: max(screenCornerRadius - inset, 0)
    )
  }

  private func updateAnimation() {
    guard isActive else {
      withAnimation(.easeOut(duration: 0.18)) {
        pulse = false
        morph = false
      }
      return
    }
    guard !reduceMotion else {
      withAnimation(.easeOut(duration: 0.18)) {
        pulse = true
        morph = false
      }
      return
    }
    pulse = false
    morph = false
    DispatchQueue.main.async {
      withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
        pulse = true
      }
      withAnimation(.easeInOut(duration: 5.8).repeatForever(autoreverses: true)) {
        morph = true
      }
    }
  }

  private struct EdgeGlowMetrics {
    let size: CGSize
    let edgeWidth: CGFloat
    let blurRadius: CGFloat
    let inset: CGFloat
    let screenshotFillWidth: CGFloat
    let cornerRadius: CGFloat
  }
}

extension Color {
  fileprivate static let glowSky = Color(red: 0.34, green: 0.70, blue: 1.0)
  fileprivate static let glowCyan = Color(red: 0.34, green: 0.86, blue: 0.95)
  fileprivate static let glowMint = Color(red: 0.38, green: 0.90, blue: 0.64)
  fileprivate static let glowLime = Color(red: 0.76, green: 0.92, blue: 0.43)
  fileprivate static let glowGold = Color(red: 1.0, green: 0.78, blue: 0.28)
  fileprivate static let glowRose = Color(red: 1.0, green: 0.48, blue: 0.66)
  fileprivate static let glowPink = Color(red: 0.94, green: 0.46, blue: 0.96)
  fileprivate static let glowViolet = Color(red: 0.58, green: 0.56, blue: 1.0)
}
#endif
