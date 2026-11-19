import Foundation
import Testing
@testable import Grada

struct WidgetTests {
    private let card = WidgetCard(id: "steps", title: "Steps", symbol: "figure.walk", tint: .green, period: "Today",
                                  value: "8,420", unit: "", comparison: "−1,580 of 10,000", comparisonWarns: false,
                                  style: .rated(.fair))

    @Test func ratingColorsTheValueOnAnyCard() {
        let snapshot = CardSnapshot(period: "Today", value: "8,420", tone: .warning, rating: .fair)
        #expect(snapshot.valueStyle(for: .steps) == .rated(.fair))
    }

    @Test func onlyScoresColorTheValueByTone() {
        let snapshot = CardSnapshot(period: "Today", value: "40", tone: .warning)
        #expect(snapshot.valueStyle(for: .recovery) == .warning)
        #expect(snapshot.valueStyle(for: .steps) == .plain)
        #expect(snapshot.comparisonWarns(for: .steps))
        #expect(!snapshot.comparisonWarns(for: .recovery))
    }

    @Test func widgetsOfferOnlySingleValueCards() {
        #expect(WidgetPublisher.kinds.contains(.recovery))
        #expect(WidgetPublisher.kinds.allSatisfy { $0.size == .square })
        #expect(!WidgetPublisher.kinds.contains(.healthStatus))
        #expect(WidgetPublisher.kinds.allSatisfy { !$0.isRetired })
    }

    @Test func cardsKeepTheirValueOnTheDayTheyWereBuilt() throws {
        let calendar = Calendar(identifier: .gregorian)
        let built = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 9)))
        let published = WidgetCards(date: built, colorBlind: false, cards: [card])
        #expect(published.card("steps", on: built.addingTimeInterval(3600), calendar: calendar)?.value == "8,420")
        // After midnight "Today" is wrong, so the value waits for the app's next import.
        let nextDay = built.addingTimeInterval(86_400)
        #expect(published.card("steps", on: nextDay, calendar: calendar)?.value == nil)
        #expect(published.card("steps", on: nextDay, calendar: calendar)?.title == "Steps")
        #expect(published.card("recovery", on: built, calendar: calendar) == nil)
    }

    @Test func publishedCardsSurviveEncoding() throws {
        let published = WidgetCards(date: .now, colorBlind: true, cards: [card])
        let decoded = try JSONDecoder().decode(WidgetCards.self, from: try JSONEncoder().encode(published))
        #expect(decoded.cards == [card])
        #expect(decoded.colorBlind)
    }

    @Test func widgetCardCarriesTheHomeCardsLook() {
        let snapshot = CardSnapshot(period: "Today", value: "72", unit: "%", tone: .good)
        let card = WidgetPublisher.card(.recovery, snapshot)
        #expect(card.id == "recovery")
        #expect(card.title == CardKind.recovery.title)
        #expect(card.tint == .green)
        #expect(card.style == .good)
    }
}
