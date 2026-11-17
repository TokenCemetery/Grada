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
        let sources = importer?.sources ?? []
        return (sources.contains { $0.age() != nil }, sources.contains { $0.biologicalSex() != nil })
    }

    /// Pulls the latest days from Apple Health, then rebuilds the cards.
    func refresh(_ cards: [CardID], goals: GoalHistory) async {
        await importer?.importRecent()
        await reload(cards, goals: goals)
    }

    /// Rebuilds the cards from data already imported.
    func reload(_ cards: [CardID], goals: GoalHistory) async {
        var builder = SnapshotBuilder(source: source)
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
