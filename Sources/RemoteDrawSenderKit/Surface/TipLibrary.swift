//
//  All sixteen tips, as a persistent sheet.
//
//  The dial carries four. The other twelve live here, because a radial menu of
//  sixteen instruments is a scroll wheel and not a choice — and because a
//  library is the place where a person compares marks rather than picks a noun.
//  Every cell draws its instrument with the real renderer at the colour and
//  width the board is actually set to.
//
//  Reached by releasing on "All tips": the dial dismisses first, the sheet
//  arrives second, and the host suspends drawing input for as long as it is up.
//
#if canImport(UIKit) && !os(watchOS)
  import SwiftUI

  public struct RemoteDrawTipLibrarySheet: View {
    let currentKind: DrawingStyleKind
    /// The colour the board is set to. Changing tip never changes it.
    let colorHex: String
    /// The width to draw specimens at — the width this tip will restore.
    let width: Double
    /// Optional remembered widths, keyed by the tip's stable raw value.
    let rememberedWidths: [String: Double]
    let onSelect: (DrawingStyleKind) -> Void

    public init(
      currentKind: DrawingStyleKind,
      colorHex: String,
      width: Double,
      rememberedWidths: [String: Double] = [:],
      onSelect: @escaping (DrawingStyleKind) -> Void
    ) {
      self.currentKind = currentKind
      self.colorHex = colorHex
      self.width = width
      self.rememberedWidths = rememberedWidths
      self.onSelect = onSelect
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.remoteDrawAppearance) private var appearance
    @State private var query = ""

    private var columns: [GridItem] {
      [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
      ]
    }

    public var body: some View {
      NavigationStack {
        Group {
          if matches.isEmpty {
            ContentUnavailableView {
              Label("No matching tips", systemImage: "magnifyingglass")
            } description: {
              Text("Try a tip name or a family, such as Pencil or Dry media.")
            } actions: {
              Button("Clear search") { query = "" }
            }
          } else if dynamicTypeSize.isAccessibilitySize {
            // At accessibility sizes a two-column grid of 92pt cells is a grid
            // of clipped words. The same sixteen tips, as rows.
            List {
              ForEach(families) { family in
                Section(family.title) {
                  ForEach(family.kinds) { kind in
                    Button {
                      choose(kind)
                    } label: {
                      HStack(spacing: 12) {
                        specimen(kind)
                          .frame(width: 64, height: 34)
                        Text(kind.title)
                        Spacer()
                        if kind == currentKind {
                          Image(systemName: "checkmark")
                            .foregroundStyle(appearance.accent)
                        }
                      }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("remotedraw.library.tip.\(kind.rawValue)")
                    .accessibilityAddTraits(kind == currentKind ? [.isSelected] : [])
                  }
                }
              }
            }
          } else {
            ScrollView {
              LazyVGrid(columns: columns, spacing: 12) {
                ForEach(matches) { kind in
                  cell(kind)
                }
              }
              .padding(16)
            }
            .background(RemoteDrawPorcelain.opaque.opacity(0.5))
          }
        }
        .searchable(text: $query, prompt: "Search tips")
        .navigationTitle("All tips")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Close") { dismiss() }
              .accessibilityIdentifier("remotedraw.library.close")
          }
        }
      }
      .accessibilityIdentifier("remotedraw.library")
    }

    private func cell(_ kind: DrawingStyleKind) -> some View {
      let isCurrent = kind == currentKind
      return Button {
        choose(kind)
      } label: {
        VStack(alignment: .leading, spacing: 8) {
          specimen(kind)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
          HStack(spacing: 6) {
            Text(kind.title)
              .font(.subheadline.weight(.medium))
              .foregroundStyle(RemoteDrawPorcelain.graphite)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if isCurrent {
              Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(appearance.accent)
            }
          }
        }
        .padding(12)
        .frame(minHeight: 96)
        // A collection rests on the sheet; only transient puck choices float.
        // Repeating sixteen elevation shadows makes the library look muddy.
        .remoteDrawPorcelain(cornerRadius: 16, isRaised: false)
        .overlay {
          if isCurrent {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .strokeBorder(appearance.accent.opacity(0.8), lineWidth: 1.5)
          }
        }
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(kind.title))
      .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
      .accessibilityIdentifier("remotedraw.library.tip.\(kind.rawValue)")
    }

    private func specimen(_ kind: DrawingStyleKind) -> some View {
      RemoteDrawPuckSpecimen(
        kind: kind, hex: colorHex, width: specimenWidth(kind), ink: RemoteDrawPorcelain.graphite)
    }

    private func specimenWidth(_ kind: DrawingStyleKind) -> Double {
      let candidate = rememberedWidths[kind.rawValue] ?? width
      return candidate.isFinite ? min(48, max(1, candidate)) : 6
    }

    private func choose(_ kind: DrawingStyleKind) {
      onSelect(kind)
      dismiss()
    }

    private struct Family: Identifiable {
      let id: String
      let title: String
      let kinds: [DrawingStyleKind]
    }

    private var families: [Family] {
      DrawingStyleKind.Family.allCases.compactMap { family in
        let kinds = family.members.filter(self.matchesQuery)
        guard !kinds.isEmpty else { return nil }
        return Family(id: family.rawValue, title: family.rawValue, kinds: kinds)
      }
    }

    private var matches: [DrawingStyleKind] {
      DrawingStyleKind.allCases.filter(matchesQuery)
    }

    private func matchesQuery(_ kind: DrawingStyleKind) -> Bool {
      let trimmed = query.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { return true }
      if kind.title.localizedCaseInsensitiveContains(trimmed) { return true }
      return DrawingStyleKind.Family.allCases.contains { family in
        family.members.contains(kind) && family.rawValue.localizedCaseInsensitiveContains(trimmed)
      }
    }
  }
#endif
