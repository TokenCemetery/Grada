import SwiftUI

/// Placeholder until the calendar is designed.
struct CalendarView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Calendar",
                systemImage: "calendar",
                description: Text("Your past days will show up here.")
            )
            .navigationTitle("Calendar")
        }
    }
}
