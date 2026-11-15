import os
import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(HomeModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \HomeCard.position) private var cards: [HomeCard]
    @Query private var goalChanges: [GoalChange]
    @Environment(\.healthSource) private var healthSource
    @AppStorage("didSeedHomeCards") private var didSeedHomeCards = false
    @State private var isCustomizing = false

    private var cardIDs: [CardID] { cards.compactMap(\.cardID) }
    private let healthStatus = CardID(kind: .healthStatus)
    private var goals: GoalHistory { GoalHistory(goalChanges) }

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
                    card(healthStatus)
                    ForEach(HomeLayout.rows(for: cardIDs), id: \.self) { row in
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
            .navigationDestination(for: MetricRoute.self) { MetricDetailView(route: $0) }
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
        .onChange(of: cardIDs) { oldCards, newCards in
            removeDuplicateCards()
            let added = newCards.filter { !oldCards.contains($0) && model.snapshots[$0] == nil }
            if !added.isEmpty { Task { await model.reload(added, goals: goals) } }
        }
        .onChange(of: model.importer?.revision) {
            Task { await model.reload([healthStatus] + cardIDs, goals: goals) }
        }
        .onChange(of: goals) {
            Task { await model.reload([healthStatus] + cardIDs, goals: goals) }
        }
    }

    private func card(_ card: CardID) -> some View {
        CardLink(kind: card.kind, snapshot: model.snapshots[card])
    }

    private func refresh() async {
        let store = GoalStore(context: modelContext, source: healthSource)
        do { try await store.adjustIfNeeded() } catch {
            Logger(subsystem: "Grada", category: "Goals").error("Adjusting goals failed: \(error.localizedDescription)")
        }
        await model.refresh([healthStatus] + cardIDs, goals: store.history())
    }

    private func seedDefaultCardsIfNeeded() {
        guard !didSeedHomeCards else { return }
        if cards.isEmpty {
            for (position, card) in CardKind.defaultSet.enumerated() {
                modelContext.insert(HomeCard(card, position: position))
            }
        }
        didSeedHomeCards = true
    }

    /// A second device seeds the default cards before iCloud delivers the existing ones,
    /// so the same card can arrive twice. Keep the first of each kind and variant.
    private func removeDuplicateCards() {
        var seen = Set<CardID>()
        for card in cards {
            guard let id = card.cardID, !seen.insert(id).inserted else { continue }
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
        .modelContainer(for: [HomeCard.self, GoalChange.self], inMemory: true)
}
