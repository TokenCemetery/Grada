import os
import SwiftData
import SwiftUI

/// The first-launch sheet: the Home cards to start with, then the goals. Each step shows only while it's still due;
/// the sheet closes itself once both are saved.
struct OnboardingView: View {
    /// Captured when the sheet opens, so saving the cards pushes the goals instead of swapping the first screen out.
    @State private var choosesCards: Bool
    private let choosesGoals: Bool
    @State private var showsGoals = false

    init(choosesCards: Bool, choosesGoals: Bool) {
        _choosesCards = State(initialValue: choosesCards)
        self.choosesGoals = choosesGoals
    }

    var body: some View {
        NavigationStack {
            if choosesCards {
                CardPersonaView { if choosesGoals { showsGoals = true } }
                    .navigationDestination(isPresented: $showsGoals) {
                        // Going back would add a second set of cards.
                        GoalSetupView().navigationBarBackButtonHidden()
                    }
            } else {
                GoalSetupView()
            }
        }
        .interactiveDismissDisabled()
    }
}

/// Picks the persona whose cards a fresh install starts with.
private struct CardPersonaView: View {
    let onChoose: () -> Void
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SettingsKey.didSeedHomeCards) private var didSeedHomeCards = false

    var body: some View {
        List {
            ForEach(CardPersona.allCases) { persona in
                Section {
                    Button {
                        choose(persona)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(persona.title).font(.headline)
                            Text(persona.summary).font(.subheadline).foregroundStyle(.secondary)
                            Text(persona.cards.map(\.kind.title).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
            } footer: {
                Text("Change your cards any time with Edit on Home.")
            }
        }
        .navigationTitle("Choose your cards")
    }

    private func choose(_ persona: CardPersona) {
        guard !didSeedHomeCards else { return onChoose() }
        for (position, card) in persona.cards.enumerated() {
            modelContext.insert(HomeCard(card, position: position))
        }
        do {
            try modelContext.save()
        } catch {
            // Undone so the screen stays and another tap can try again, instead of marking an empty Home as chosen.
            modelContext.rollback()
            Logger(subsystem: "Grada", category: "Home").error("Saving starting cards failed: \(error.localizedDescription)")
            return
        }
        didSeedHomeCards = true
        onChoose()
    }
}
