// Chrome. UIKit-only because it speaks to the haptics engine and the
// keyboard; `swift test` runs this package on macOS, so it is guarded
// rather than ported.
#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

public struct RemoteDrawRadialMenuItem: Identifiable {
  public let id: String
  public let systemImage: String
  public let title: String
  public var isSelected: Bool
  public let action: () -> Void

  public init(
    id: String,
    systemImage: String,
    title: String,
    isSelected: Bool = false,
    action: @escaping () -> Void
  ) {
    self.id = id
    self.systemImage = systemImage
    self.title = title
    self.isSelected = isSelected
    self.action = action
  }
}

/// External activation of the radial menu: a long-press anywhere on the board
/// summons the fan at the finger. The host owns this state and feeds it from
/// the ergonomic long-press recognizer.
public struct RemoteDrawRadialSummon: Equatable {
  public enum Phase: Equatable {
    case active
    case ended
    case cancelled
  }

  public var anchor: CGPoint
  public var location: CGPoint
  public var phase: Phase

  public init(anchor: CGPoint, location: CGPoint, phase: Phase = .active) {
    self.anchor = anchor
    self.location = location
    self.phase = phase
  }
}

/// Summon-only radial tool fan. Long-press opens it under the finger, items
/// gather on an arc toward the open side of the screen (never overlapping,
/// never off screen), dragging magnifies items dock-style and highlights the
/// nearest one, releasing on it performs it. Releasing over the hub (✕) or off
/// the fan cancels, so the menu can never act by accident.
///
/// Purely visual: it consumes no touches — the host drives it through the
/// `summon` binding from the ergonomic long-press recognizer.
public struct RemoteDrawRadialToolMenu: View {
  let items: [RemoteDrawRadialMenuItem]
  @Binding var summon: RemoteDrawRadialSummon?

  @Environment(\.remoteDrawAppearance) private var appearance

  public init(items: [RemoteDrawRadialMenuItem], summon: Binding<RemoteDrawRadialSummon?>) {
    self.items = items
    self._summon = summon
  }

  @State private var layout: RemoteDrawRadialLayout?
  @State private var menuVisible = false
  @State private var highlightedIndex: Int?
  @State private var fingerLocation: CGPoint?
  @State private var pressOrigin: CGPoint?
  @State private var closeTask: Task<Void, Never>?

  public var body: some View {
    GeometryReader { proxy in
      ZStack {
        if let layout {
          menuLayer(layout: layout, in: proxy.size)
        }
      }
      .onChange(of: summon) { _, next in
        handleSummonChange(next, in: proxy.size)
      }
    }
    .allowsHitTesting(false)
  }

  // MARK: - Summon lifecycle

  private func handleSummonChange(_ next: RemoteDrawRadialSummon?, in size: CGSize) {
    guard let next else {
      close()
      return
    }
    switch next.phase {
    case .active:
      if layout == nil {
        open(at: next.anchor, in: size)
      }
      fingerLocation = next.location
      updateHighlight(for: next.location)
    case .ended:
      performHighlightedItem(at: next.location)
      close()
      summon = nil
    case .cancelled:
      close()
      summon = nil
    }
  }

  private func open(at anchor: CGPoint, in size: CGSize) {
    guard !items.isEmpty else { return }
    closeTask?.cancel()
    layout = RemoteDrawRadialSolver.solve(anchor: anchor, in: size, itemCount: items.count)
    highlightedIndex = nil
    pressOrigin = anchor
    fingerLocation = anchor
    menuVisible = false
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    Task { @MainActor in
      menuVisible = true
    }
  }

  private func close() {
    closeTask?.cancel()
    withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
      menuVisible = false
    }
    highlightedIndex = nil
    closeTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 200_000_000)
      guard !Task.isCancelled, !menuVisible else { return }
      layout = nil
      fingerLocation = nil
      pressOrigin = nil
    }
  }

  private func updateHighlight(for location: CGPoint) {
    guard let layout else { return }
    let nextIndex = layout.highlightedIndex(for: location)
    guard nextIndex != highlightedIndex else { return }
    highlightedIndex = nextIndex
    if nextIndex != nil {
      UISelectionFeedbackGenerator().selectionChanged()
    }
  }

  private func performHighlightedItem(at location: CGPoint) {
    guard let layout else { return }
    // Releasing without ever leaving the press point always cancels — even
    // when a corner press shifted the fan inward and an item happens to sit
    // near the finger.
    if let pressOrigin {
      let travel = hypot(location.x - pressOrigin.x, location.y - pressOrigin.y)
      guard travel >= 24 else { return }
    }
    guard
      let index = layout.highlightedIndex(for: location),
      items.indices.contains(index)
    else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    items[index].action()
  }

  // MARK: - Rendering

  private func menuLayer(layout: RemoteDrawRadialLayout, in size: CGSize) -> some View {
    ZStack {
      vignette(layout: layout, in: size)
      hub(at: layout.anchor)

      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        if layout.itemCenters.indices.contains(index) {
          menuItem(item, at: index, center: layout.itemCenters[index], anchor: layout.anchor)
        }
      }

      if let highlightedIndex,
         items.indices.contains(highlightedIndex),
         layout.itemCenters.indices.contains(highlightedIndex) {
        highlightLabel(
          for: items[highlightedIndex],
          at: layout.itemCenters[highlightedIndex]
        )
      }
    }
  }

  private func vignette(layout: RemoteDrawRadialLayout, in size: CGSize) -> some View {
    RadialGradient(
      colors: [
        appearance.ink.opacity(0.22),
        appearance.ink.opacity(0.06),
        .clear,
      ],
      center: UnitPoint(
        x: layout.anchor.x / max(size.width, 1),
        y: layout.anchor.y / max(size.height, 1)
      ),
      startRadius: 16,
      endRadius: layout.radius * 2.4
    )
    .opacity(menuVisible ? 1 : 0)
    .animation(.easeOut(duration: 0.18), value: menuVisible)
  }

  private func hub(at anchor: CGPoint) -> some View {
    ZStack {
      // One-shot ripple when the menu lands.
      Circle()
        .stroke(appearance.accent.opacity(0.45), lineWidth: 1.5)
        .frame(width: 44, height: 44)
        .scaleEffect(menuVisible ? 2.1 : 0.5)
        .opacity(menuVisible ? 0 : 0.8)
        .animation(.easeOut(duration: 0.55), value: menuVisible)

      ZStack {
        Circle()
          .fill(.ultraThinMaterial)
        Circle()
          .strokeBorder(
            LinearGradient(
              colors: [.white.opacity(0.9), appearance.accent.opacity(0.35)],
              startPoint: .top,
              endPoint: .bottom
            ),
            lineWidth: 1
          )
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(appearance.ink.opacity(highlightedIndex == nil ? 0.6 : 0.15))
          .animation(.easeOut(duration: 0.12), value: highlightedIndex == nil)
      }
      .frame(width: 42, height: 42)
      .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
      .scaleEffect(menuVisible ? 1 : 0.4)
      .opacity(menuVisible ? 1 : 0)
      .animation(.spring(response: 0.3, dampingFraction: 0.75), value: menuVisible)
    }
    .position(anchor)
  }

  private func menuItem(
    _ item: RemoteDrawRadialMenuItem,
    at index: Int,
    center: CGPoint,
    anchor: CGPoint
  ) -> some View {
    let isHighlighted = index == highlightedIndex
    let diameter = RemoteDrawRadialMetrics.itemDiameter
    return ZStack {
      Circle()
        .fill(.regularMaterial)
      // Top sheen so the glass reads as curved.
      Circle()
        .fill(
          LinearGradient(
            colors: [.white.opacity(0.6), .white.opacity(0.04)],
            startPoint: .top,
            endPoint: .bottom
          )
        )
      Circle()
        .fill(appearance.accent)
        .opacity(isHighlighted ? 1 : 0)
        .animation(.easeOut(duration: 0.14), value: isHighlighted)
      Circle()
        .strokeBorder(
          isHighlighted
            ? AnyShapeStyle(.white.opacity(0.85))
            : item.isSelected
              ? AnyShapeStyle(appearance.accent.opacity(0.9))
              : AnyShapeStyle(
                LinearGradient(
                  colors: [.white.opacity(0.85), .black.opacity(0.07)],
                  startPoint: .top,
                  endPoint: .bottom
                )
              ),
          lineWidth: isHighlighted || item.isSelected ? 2 : 1
        )
      Image(systemName: item.systemImage)
        .font(.system(size: 20, weight: .bold))
        .foregroundStyle(
          isHighlighted
            ? AnyShapeStyle(.white)
            : item.isSelected
              ? AnyShapeStyle(appearance.accent)
              : AnyShapeStyle(appearance.ink.opacity(0.78))
        )
        .shadow(color: isHighlighted ? .black.opacity(0.18) : .clear, radius: 1, y: 1)
    }
    .frame(width: diameter, height: diameter)
    .shadow(
      color: isHighlighted ? appearance.accent.opacity(0.55) : .black.opacity(0.15),
      radius: isHighlighted ? 18 : 10,
      y: 5
    )
    // Dock-style proximity magnification, driven directly by the finger so it
    // tracks at full frame rate (no implicit animation on this layer).
    .scaleEffect(dockScale(for: center, isHighlighted: isHighlighted))
    // Entrance/exit: items fly out of the hub with a per-item stagger.
    .scaleEffect(menuVisible ? 1 : 0.1)
    .position(menuVisible ? center : anchor)
    .opacity(menuVisible ? 1 : 0)
    .animation(
      .spring(response: 0.36, dampingFraction: 0.74)
        .delay(menuVisible ? Double(index) * 0.02 : 0),
      value: menuVisible
    )
    .accessibilityLabel(item.title)
  }

  private func dockScale(for center: CGPoint, isHighlighted: Bool) -> CGFloat {
    var scale: CGFloat = 1
    if let fingerLocation {
      let distance = hypot(center.x - fingerLocation.x, center.y - fingerLocation.y)
      let proximity = max(0, 1 - distance / 140)
      scale += 0.14 * proximity * proximity
    }
    if isHighlighted {
      scale = max(scale, 1.2)
    }
    return scale
  }

  private func highlightLabel(for item: RemoteDrawRadialMenuItem, at center: CGPoint) -> some View {
    let itemRadius = RemoteDrawRadialMetrics.itemDiameter / 2
    let aboveY = center.y - itemRadius - 26
    let labelY = aboveY < 40 ? center.y + itemRadius + 26 : aboveY
    return Text(item.title)
      .font(.system(size: 13, weight: .bold, design: .rounded))
      .foregroundStyle(.white)
      .padding(.horizontal, 13)
      .padding(.vertical, 6)
      .background(Capsule(style: .continuous).fill(appearance.accent))
      .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
      .shadow(color: appearance.accent.opacity(0.45), radius: 10, y: 4)
      .position(x: center.x, y: labelY)
      .transition(.opacity.combined(with: .scale(scale: 0.85)))
      .animation(.spring(response: 0.22, dampingFraction: 0.8), value: highlightedIndex)
  }
}
#endif
