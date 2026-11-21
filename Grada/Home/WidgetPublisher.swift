import os
import SwiftData
import WidgetKit

/// Writes the cards the widgets can show to the App Group container, then asks WidgetKit to redraw them.
/// Runs after each import of new Health data, including in the background (#129).
final class WidgetPublisher {
    /// Single-value cards. Wide cards and the workouts calendar don't fit a widget.
    static let kinds = CardKind.gallery.filter { $0.size == .square }

    private let source: HealthDataSource
    private let context: ModelContext
    private nonisolated static let logger = Logger(subsystem: "Grada", category: "Widgets")

    init(source: HealthDataSource, context: ModelContext) {
        self.source = source
        self.context = context
    }

    func update() async {
        var builder: SnapshotBuilder
        do { builder = SnapshotBuilder(source: try await source.withDaysLoaded(HomeModel.cardDays)) }
        catch {
            Self.logger.error("Loading stored days failed: \(error.localizedDescription)")
            builder = SnapshotBuilder(source: source)
        }
        builder.goals = GoalHistory((try? context.fetch(FetchDescriptor<GoalChange>())) ?? [])
        let now = builder.now
        var snapshots: [CardKind: CardSnapshot] = [:]
        await withTaskGroup(of: (CardKind, CardSnapshot?).self) { group in
            for kind in Self.kinds {
                group.addTask {
                    do { return (kind, try await builder.snapshot(for: kind, variant: kind.defaultVariant)) }
                    catch {
                        Self.logger.error("Loading \(kind.rawValue) failed: \(error.localizedDescription)")
                        return (kind, nil)
                    }
                }
            }
            for await (kind, snapshot) in group { snapshots[kind] = snapshot }
        }
        let cards = Self.kinds.compactMap { kind in snapshots[kind].map { Self.card(kind, $0) } }
        let colorBlind = UserDefaults.standard.bool(forKey: SettingsKey.colorBlindPalette)
        Self.save(WidgetCards(date: now, colorBlind: colorBlind, cards: cards))
    }

    /// The widgets read the palette from their file, so a change in Settings rewrites it.
    static func setColorBlind(_ colorBlind: Bool) {
        guard var published = WidgetCards.load(), published.colorBlind != colorBlind else { return }
        published.colorBlind = colorBlind
        save(published)
    }

    static func card(_ kind: CardKind, _ snapshot: CardSnapshot) -> WidgetCard {
        WidgetCard(id: kind.rawValue, title: kind.title, symbol: kind.symbol, tint: kind.category.tint,
                   period: snapshot.period, value: snapshot.value, unit: snapshot.unit,
                   comparison: snapshot.comparison, comparisonWarns: snapshot.comparisonWarns(for: kind),
                   style: snapshot.valueStyle(for: kind))
    }

    private static func save(_ cards: WidgetCards) {
        do {
            try cards.save()
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetCards.widgetKind)
        } catch {
            logger.error("Saving widget cards failed: \(error.localizedDescription)")
        }
    }
}
