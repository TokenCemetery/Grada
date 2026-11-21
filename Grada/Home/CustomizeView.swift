import SwiftData
import SwiftUI

/// Reorder and remove home cards, and add new ones from the gallery.
struct CustomizeView: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HomeCard.position) private var cards: [HomeCard]
    @Query private var goalChanges: [GoalChange]

    var body: some View {
        let onHome = Set(cards.compactMap(\.cardID))
        NavigationStack {
            List {
                Section("On Home") {
                    HStack {
                        CardRow(card: CardID(kind: .healthStatus))
                        Text("Pinned").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(cards) { card in
                        if let id = card.cardID { CardRow(card: id) }
                    }
                    .onMove(perform: move)
                    .onDelete(perform: delete)
                }
                ForEach(CardCategory.allCases, id: \.self) { category in
                    let available = CardID.gallery.filter { $0.kind.category == category && !onHome.contains($0) }
                    if !available.isEmpty {
                        Section(category.addTitle) {
                            ForEach(available) { card in
                                Button { add(card) } label: {
                                    HStack {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.title3)
                                        CardRow(card: card)
                                        if model.snapshots[card].map({ $0.value == nil }) == true {
                                            Text("No data yet").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .tint(.primary)
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }.fontWeight(.semibold)
            }
            .task {
                // Find out which gallery cards have data, for the "No data yet" labels. From data already imported:
                // Home imports on its own refreshes.
                let missing = CardID.gallery.filter { model.snapshots[$0] == nil }
                if !missing.isEmpty { await model.reload(missing, goals: GoalHistory(goalChanges)) }
            }
        }
    }

    private func add(_ card: CardID) {
        withAnimation {
            modelContext.insert(HomeCard(card, position: (cards.last?.position ?? -1) + 1))
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = cards
        ordered.move(fromOffsets: source, toOffset: destination)
        renumber(ordered)
    }

    private func delete(at offsets: IndexSet) {
        var ordered = cards
        for index in offsets { modelContext.delete(cards[index]) }
        ordered.remove(atOffsets: offsets)
        renumber(ordered)
    }

    private func renumber(_ ordered: [HomeCard]) {
        for (position, card) in ordered.enumerated() where card.position != position {
            card.position = position
        }
    }
}

private struct CardRow: View {
    let card: CardID

    var body: some View {
        let kind = card.kind
        let size = switch kind.size {
        case .square: String(localized: "Square", comment: "Card size: one column")
        case .wide: String(localized: "Wide", comment: "Card size: two columns")
        case .big: String(localized: "Big", comment: "Card size: two columns, two squares tall")
        }
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.category.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(kind.title)
                Text(kind.variants.count > 1 ? String(localized: "\(card.variant.title) · \(size)") : size)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

#Preview {
    CustomizeView()
        .environment(HomeModel(source: SampleDataSource()))
        .modelContainer(for: [HomeCard.self, GoalChange.self], inMemory: true)
}
