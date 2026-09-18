import SwiftUI
import SwiftData

/// First launch.
///
/// The app used to open on an empty list. That's not a disaster — the empty
/// state offers four ways in — but it leaves two things unsaid that the whole
/// analysis depends on. It doesn't explain that nothing leaves the device,
/// which is the reason someone would choose this over Strava. And it doesn't
/// ask for a max heart rate, without which zones, training load and readiness
/// all fall back to estimates from whatever data happens to exist.
///
/// Three screens, every field skippable, and it never appears again.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @AppStorage(AthleteProfile.Key.hasOnboarded) private var hasOnboarded = false
    @AppStorage(UnitSystem.defaultsKey) private var unitSystem: UnitSystem = .metric
    @AppStorage(AthleteProfile.Key.maxHeartRate) private var maxHeartRate = 0
    @AppStorage(AthleteProfile.Key.restingHeartRate) private var restingHeartRate = 0
    @AppStorage(AthleteProfile.Key.ftpWatts) private var ftp = 0

    /// What the athlete chose to do with their data, so the caller can act.
    var onFinish: (Outcome) -> Void

    enum Outcome: Equatable {
        case importFile
        case connectService
        case seedDemo
        case nothing
    }

    @State private var page = 0
    @State private var age = 35

    /// Karvonen's age estimate. Crude — individual maxima vary by ±10–12 bpm —
    /// but a starting point beats zero, which makes every zone meaningless.
    private var estimatedMax: Int { 220 - age }

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                welcome.tag(0)
                profile.tag(1)
                firstData.tag(2)
            }
            #if os(iOS)
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if page < 2 {
                        Button("Skip") { finish(.nothing) }
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    // MARK: - Pages

    private var welcome: some View {
        Page(title: "Your training, on your device") {
            VStack(alignment: .leading, spacing: 18) {
                Bullet(icon: "doc.badge.gearshape",
                       title: "Built on your .fit files",
                       detail: "The files your watch already writes, read directly — every lap, every sample, not a summary someone else decided to keep.")
                Bullet(icon: "lock.shield",
                       title: "No account, no server",
                       detail: "There's nothing to sign up for and nowhere for your training to go. It lives in a database on this device, and in a backup if you make one.")
                Bullet(icon: "chart.xyaxis.line",
                       title: "The numbers coaches use",
                       detail: "Training load, fitness and fatigue, intensity distribution, thresholds estimated from what you've actually done.")
            }
        } action: {
            Button("Continue") { page = 1 }
                .buttonStyle(.borderedProminent)
        }
    }

    private var profile: some View {
        Page(title: "A few numbers") {
            VStack(alignment: .leading, spacing: 20) {
                Text("Zones, training load and readiness are all computed against your own heart rate. Without a maximum they fall back to the highest figure in your data, which is usually a little low.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker("Units", selection: $unitSystem) {
                    Text("Metric").tag(UnitSystem.metric)
                    Text("Imperial").tag(UnitSystem.imperial)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 6) {
                    Stepper("Age: \(age)", value: $age, in: 12...95)
                    HStack {
                        Text("Max heart rate")
                        Spacer()
                        Text(maxHeartRate > 0 ? "\(maxHeartRate) bpm" : "not set")
                            .foregroundStyle(.secondary)
                    }
                    Stepper("", value: $maxHeartRate, in: 0...230, step: 1)
                        .labelsHidden()
                    Button("Use the age estimate (\(estimatedMax) bpm)") {
                        maxHeartRate = estimatedMax
                    }
                    .font(.caption)
                    Text("If you've seen a higher number on a hard effort, use that instead — this estimate is ±10 bpm at best.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Resting heart rate")
                        Spacer()
                        Text(restingHeartRate > 0 ? "\(restingHeartRate) bpm" : "optional")
                            .foregroundStyle(.secondary)
                    }
                    Stepper("", value: $restingHeartRate, in: 0...100, step: 1)
                        .labelsHidden()
                }
            }
        } action: {
            VStack(spacing: 8) {
                Button("Continue") { page = 2 }
                    .buttonStyle(.borderedProminent)
                Text("All of this can be changed, or estimated from your data, in Settings later.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var firstData: some View {
        Page(title: "Bring in some training") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Any of these, now or later.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Bullet(icon: "square.and.arrow.down",
                       title: "Import .fit files",
                       detail: "One, or a whole folder from your watch's export.")
                Bullet(icon: "arrow.triangle.2.circlepath",
                       title: "Connect Strava or intervals.icu",
                       detail: "Pulls your history, including per-second streams and watch laps.")
                Bullet(icon: "wand.and.stars",
                       title: "Try it with sample data",
                       detail: "A synthetic season, so every screen has something in it. You can delete it afterwards.")
            }
        } action: {
            VStack(spacing: 10) {
                Button("Import .fit files…") { finish(.importFile) }
                    .buttonStyle(.borderedProminent)
                Button("Connect a service…") { finish(.connectService) }
                Button("Try it with sample data") { finish(.seedDemo) }
                Button("I'll do it later") { finish(.nothing) }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Finishing

    private func finish(_ outcome: Outcome) {
        // Set before dismissing, so a crash on the way out doesn't bring the
        // flow back on the next launch.
        hasOnboarded = true
        onFinish(outcome)
        dismiss()
    }
}

// MARK: - Layout

private struct Page<Content: View, Action: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 16)
            }
            VStack(spacing: 0) {
                action()
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    // Clear of the page-style dots.
                    .padding(.bottom, 44)
            }
            .background(.bar)
        }
    }
}

private struct Bullet: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
