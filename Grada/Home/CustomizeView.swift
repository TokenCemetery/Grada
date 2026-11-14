import SwiftData
import SwiftUI

/// Reorder and remove home cards, and add new ones from the gallery.
struct CustomizeView: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HomeCard.position) private var cards: [HomeCard]

    var body: some View {
        let onHome = Set(cards.compactMap(\.kind))
        NavigationStack {
            List {
                Section("On Home") {
                    HStack {
                        CardRow(kind: .healthStatus)
                        Text("Pinned").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(cards) { card in
                        if let kind = card.kind { CardRow(kind: kind) }
                    }
                    .onMove(perform: move)
                    .onDelete(perform: delete)
                }
                ForEach(CardCategory.allCases, id: \.self) { category in
                    let available = CardKind.gallery.filter { $0.category == category && !onHome.contains($0) }
                    if !available.isEmpty {
                        Section("Add \(category.title.lowercased())") {
                            ForEach(available) { kind in
                                Button { add(kind) } label: {
                                    HStack {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.title3)
                                        CardRow(kind: kind)
                                        if model.snapshots[kind].map({ $0.value == nil }) == true {
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
                // Find out which gallery cards have data, for the "No data yet" labels.
                await model.refresh(CardKind.gallery.filter { model.snapshots[$0] == nil })
            }
        }
    }

    private func add(_ kind: CardKind) {
        withAnimation {
            modelContext.insert(HomeCard(kind: kind, position: (cards.last?.position ?? -1) + 1))
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
    let kind: CardKind

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.category.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(kind.title)
                Text(kind.size == .wide ? "Wide" : "Square")
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
        .modelContainer(for: HomeCard.self, inMemory: true)
}
