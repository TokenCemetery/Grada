import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \HomeCard.position) private var cards: [HomeCard]
    @AppStorage("didSeedHomeCards") private var didSeedHomeCards = false
    @State private var isCustomizing = false

    private var kinds: [CardKind] { cards.compactMap(\.kind) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let progress = model.importer?.historyProgress {
                        ImportProgressView(progress: progress)
                    }
                    card(.healthStatus)
                    ForEach(HomeLayout.rows(for: kinds), id: \.self) { row in
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(row) { card($0) }
                            if row.count == 1, row[0].size == .square {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Today")
            .toolbar {
                Button("Edit") { isCustomizing = true }
            }
            .refreshable { await refresh() }
            .sheet(isPresented: $isCustomizing) {
                CustomizeView()
            }
        }
        .task {
            seedDefaultCardsIfNeeded()
            await refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        .onChange(of: kinds) { oldKinds, newKinds in
            removeDuplicateCards()
            let added = newKinds.filter { !oldKinds.contains($0) && model.snapshots[$0] == nil }
            if !added.isEmpty { Task { await model.reload(added) } }
        }
        .onChange(of: model.importer?.revision) {
            Task { await model.reload([.healthStatus] + kinds) }
        }
    }

    private func card(_ kind: CardKind) -> some View {
        CardView(kind: kind, snapshot: model.snapshots[kind])
    }

    private func refresh() async {
        await model.refresh([.healthStatus] + kinds)
    }

    private func seedDefaultCardsIfNeeded() {
        guard !didSeedHomeCards else { return }
        if cards.isEmpty {
            for (position, kind) in CardKind.defaultSet.enumerated() {
                modelContext.insert(HomeCard(kind: kind, position: position))
            }
        }
        didSeedHomeCards = true
    }

    /// A second device seeds the default cards before iCloud delivers the existing ones,
    /// so the same card can arrive twice. Keep the first of each kind.
    private func removeDuplicateCards() {
        var seen = Set<String>()
        for card in cards where !seen.insert(card.kindRawValue).inserted {
            modelContext.delete(card)
        }
    }
}

private struct ImportProgressView: View {
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Importing your Apple Health history")
                .font(.subheadline.weight(.semibold))
            ProgressView(value: progress)
            Text("Recent days are ready. Older data keeps loading while you use the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    HomeView()
        .environment(HomeModel(source: SampleDataSource()))
        .modelContainer(for: HomeCard.self, inMemory: true)
}
