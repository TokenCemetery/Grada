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
                    HomeGrid(items: cardIDs) { card($0) }
                }
                .padding(.horizontal)
                .padding(.bottom)
                .readableWidth()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Today")
            .navigationDestination(for: MetricRoute.self) { MetricDetailView(route: $0) }
            .navigationDestination(for: WorkoutRoute.self) { WorkoutDetailView(workout: $0.workout) }
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

extension View {
    /// Centers content in a column of limited width, so wide screens (iPad, landscape) don't stretch it.
    func readableWidth() -> some View {
        frame(maxWidth: 720).frame(maxWidth: .infinity)
    }
}

/// Cards packed by `HomeLayout` into rows of equal columns: 3 where there's room, as on iPad
/// or a landscape iPhone, otherwise 2.
struct HomeGrid<Item: HomeLayoutItem & Identifiable, Card: View>: View {
    let items: [Item]
    @ViewBuilder let card: (Item) -> Card
    @State private var columns = 2

    var body: some View {
        VStack(spacing: ColumnsLayout.spacing) {
            ForEach(HomeLayout.rows(for: items, columns: columns), id: \.self) { row in
                switch row {
                case .cards(let cards):
                    let squares = cards.count { $0.size == .square }
                    ColumnsLayout(columns: columns) {
                        ForEach(cards) { item in
                            card(item).layoutValue(key: ColumnSpan.self, value: item.size == .square ? 1 : columns - squares)
                        }
                    }
                case .big(let item, let beside):
                    let besideColumns = columns - 2
                    ColumnsLayout(columns: columns) {
                        card(item).layoutValue(key: ColumnSpan.self, value: 2)
                        VStack(spacing: ColumnsLayout.spacing) {
                            ForEach([beside.prefix(besideColumns), beside.dropFirst(besideColumns)], id: \.self) { squares in
                                ColumnsLayout(columns: besideColumns) {
                                    ForEach(squares) { card($0) }
                                }
                            }
                        }
                        .layoutValue(key: ColumnSpan.self, value: besideColumns)
                    }
                }
            }
        }
        // 540pt keeps 3 columns at least about as wide as a square card is tall.
        .onGeometryChange(for: Int.self) { $0.size.width >= 540 ? 3 : 2 } action: { columns = $0 }
    }
}

private struct ColumnSpan: LayoutValueKey {
    static let defaultValue = 1
}

/// Places cards side by side on a grid of equal columns. Each card spans `ColumnSpan` columns,
/// and every card is stretched to the row's tallest card.
private struct ColumnsLayout: Layout {
    static let spacing: CGFloat = 12
    let columns: Int

    private func widths(_ subviews: Subviews, in width: CGFloat) -> [CGFloat] {
        let column = (width - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return subviews.map {
            let span = CGFloat($0[ColumnSpan.self])
            return column * span + Self.spacing * (span - 1)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let height = zip(subviews, widths(subviews, in: width))
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(subviews, in: bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + Self.spacing
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
