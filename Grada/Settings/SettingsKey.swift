/// UserDefaults keys that several screens share through `@AppStorage`, declared once so a rename can't split a
/// setting (#123). Keys used by one type are declared beside it, e.g. `SleepSchedule` and `EnteredProfile`.
nonisolated enum SettingsKey {
    static let appearance = "appearance"
    static let calendarMetric = "calendarMetric"
    static let colorBlindPalette = "colorBlindPalette"
    static let dismissedJournalSuggestions = "dismissedJournalSuggestions"
    static let didSeedHomeCards = "didSeedHomeCards"
}
