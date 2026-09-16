import SwiftUI

struct RootView: View {
    /// Five tabs is the ceiling before iOS collapses the rest behind "More".
    /// Routes earns a tab because it's an active tool you reach for; Shoes is a
    /// set-and-glance tracker, so it lives behind the Dashboard (which already
    /// surfaces its wear alerts). Import and settings sit in the Workouts toolbar.
    var body: some View {
        TabView {
            WorkoutListView()
                .tabItem { Label("Workouts", systemImage: "figure.run") }
            RecoveryView()
                .tabItem { Label("Recovery", systemImage: "heart.text.square") }
            RouteListView()
                .tabItem { Label("Routes", systemImage: "map") }
            StrengthListView()
                .tabItem { Label("Strength", systemImage: "dumbbell") }
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "chart.line.uptrend.xyaxis") }
        }
    }
}
