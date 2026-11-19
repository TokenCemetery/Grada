import Foundation
import Observation
import os

/// Loads card snapshots from the health data source.
@Observable
final class HomeModel {
    private(set) var snapshots: [CardID: CardSnapshot] = [:]
    /// Nil in sample-data mode, where there is nothing to import.
    let importer: HealthImporter?

    private let source: HealthDataSource
    /// The longest history any card reads (VO₂ max), so one fetch of stored rows serves every card (#121).
    static let cardDays = 90
    private let logger = Logger(subsystem: "Grada", category: "HomeModel")

    init(source: HealthDataSource, importer: HealthImporter? = nil) {
        self.source = source
        self.importer = importer
    }

    /// What Apple Health says about the user, for the read-only profile in Settings.
    func loadProfile() async -> HealthProfile {
        do { return try await HealthProfile.load(from: source) }
        catch {
            logger.error("Loading profile failed: \(error.localizedDescription)")
            return HealthProfile()
        }
    }

    /// Whether a source such as Apple Health provides age and sex, so what's entered in Settings › Profile isn't used.
    func sourcesProvideProfile() -> (age: Bool, sex: Bool) {
        source.providesProfile()
    }

    /// Pulls the latest days from Apple Health, then rebuilds the cards.
    func refresh(_ cards: [CardID], goals: GoalHistory) async {
        await importer?.importRecent()
        await reload(cards, goals: goals)
    }

    /// Rebuilds the cards from data already imported.
    func reload(_ cards: [CardID], goals: GoalHistory) async {
        var builder: SnapshotBuilder
        do { builder = SnapshotBuilder(source: try await source.withDaysLoaded(Self.cardDays)) }
        catch {
            // Each card then fetches for itself.
            logger.error("Loading stored days failed: \(error.localizedDescription)")
            builder = SnapshotBuilder(source: source)
        }
        builder.goals = goals
        await withTaskGroup(of: (CardID, Result<CardSnapshot, Error>).self) { group in
            for card in Set(cards) {
                group.addTask {
                    do { return (card, .success(try await builder.snapshot(for: card.kind, variant: card.variant))) }
                    catch { return (card, .failure(error)) }
                }
            }
            for await (card, result) in group {
                switch result {
                case .success(let snapshot):
                    snapshots[card] = snapshot
                case .failure(let error):
                    // Keep the last good snapshot; the next refresh retries.
                    logger.error("Loading \(card.kind.rawValue) failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
