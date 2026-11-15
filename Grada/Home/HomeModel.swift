import Foundation
import Observation
import os

/// Loads card snapshots from the health data source.
@Observable
final class HomeModel {
    private(set) var snapshots: [CardKind: CardSnapshot] = [:]
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

    /// Pulls the latest days from Apple Health, then rebuilds the cards.
    func refresh(_ kinds: [CardKind], goals: GoalHistory) async {
        await importer?.importRecent()
        await reload(kinds, goals: goals)
    }

    /// Rebuilds the cards from data already imported.
    func reload(_ kinds: [CardKind], goals: GoalHistory) async {
        var builder = SnapshotBuilder(source: source)
        builder.goals = goals
        await withTaskGroup(of: (CardKind, Result<CardSnapshot, Error>).self) { group in
            for kind in Set(kinds) {
                group.addTask {
                    do { return (kind, .success(try await builder.snapshot(for: kind))) }
                    catch { return (kind, .failure(error)) }
                }
            }
            for await (kind, result) in group {
                switch result {
                case .success(let snapshot):
                    snapshots[kind] = snapshot
                case .failure(let error):
                    // Keep the last good snapshot; the next refresh retries.
                    logger.error("Loading \(kind.rawValue) failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
