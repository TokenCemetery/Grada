import Foundation
import Observation
import os

/// Loads card snapshots from the health data source.
@Observable
final class HomeModel {
    private(set) var snapshots: [CardKind: CardSnapshot] = [:]

    private let source: HealthDataSource
    private var didRequestAuthorization = false
    private let logger = Logger(subsystem: "DailyHealth", category: "HomeModel")

    init(source: HealthDataSource) {
        self.source = source
    }

    func refresh(_ kinds: [CardKind]) async {
        if !didRequestAuthorization {
            do {
                try await source.requestAuthorization()
            } catch {
                logger.error("Health authorization failed: \(error.localizedDescription)")
            }
            didRequestAuthorization = true
        }

        let builder = SnapshotBuilder(source: source)
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
