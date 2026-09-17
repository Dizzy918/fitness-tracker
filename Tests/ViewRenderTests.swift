import XCTest
import SwiftUI
import SwiftData
import CoreLocation
@testable import FitnessTracker

/// Renders each screen through `ImageRenderer` so a broken body — a bad Chart
/// axis config, a nil-unwrap in a computed property, a missing environment
/// value — fails here instead of at runtime on device.
@MainActor
final class ViewRenderTests: XCTestCase {

    /// Containers must outlive the render. A view whose `.task` is still running
    /// when its container deallocates would touch reset models and crash — the
    /// real app holds its container for the whole process lifetime, so keep a
    /// strong reference here too rather than letting the harness fake a teardown
    /// the app never does.
    /// Never cleared: a SwiftUI `.task` started during a render can run after the
    /// test method returns, and releasing its container first would reset the
    /// models underneath it. Holding a handful of in-memory containers for the
    /// process lifetime is cheaper than a flaky suite.
    private nonisolated(unsafe) static var retainedContainers: [ModelContainer] = []

    /// Seeded containers, keyed by season length.
    ///
    /// Seeding a season and writing its sample streams costs well over a second;
    /// doing it once per render test dominated the whole suite's runtime. These
    /// tests only read, so one container per `weeks` value serves all of them.
    private nonisolated(unsafe) static var seededByWeeks: [Int: ModelContainer] = [:]

    private func seededContainer(weeks: Int = 6) throws -> ModelContainer {
        if let existing = Self.seededByWeeks[weeks] { return existing }

        let container = try ModelContainer(
            for: Workout.self, Shoe.self, StrengthSession.self, SetEntry.self,
                Exercise.self, DailyMetric.self, Route.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        DemoData.seed(into: context, weeks: weeks)
        try context.save()
        Self.retainedContainers.append(container)
        Self.seededByWeeks[weeks] = container
        return container
    }

    private func emptyContainer() throws -> ModelContainer {
        let container = try ModelContainer(
            for: Workout.self, Shoe.self, StrengthSession.self, SetEntry.self,
                Exercise.self, DailyMetric.self, Route.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        Self.retainedContainers.append(container)
        return container
    }

    private func assertRenders<V: View>(_ view: V, container: ModelContainer,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) async throws {
        let renderer = ImageRenderer(
            content: view
                .modelContainer(container)
                .frame(width: 900, height: 1600)
        )
        let image = renderer.cgImage
        XCTAssertNotNil(image, "view failed to render", file: file, line: line)
        XCTAssertGreaterThan(image?.width ?? 0, 0, file: file, line: line)
        // Give any `.task` the view started a chance to finish while its
        // container is still alive.
        await Task.yield()
    }

    // MARK: - Populated

    func testRootViewRenders() async throws {
        try await assertRenders(RootView(), container: try seededContainer())
    }

    func testDashboardRendersWithData() async throws {
        // Exercises weekly buckets, A:C ratio, moving average, reversed pace axis.
        try await assertRenders(DashboardView(), container: try seededContainer())
    }

    func testWorkoutListRendersWithData() async throws {
        try await assertRenders(WorkoutListView(), container: try seededContainer())
    }

    func testShoeListRendersWithData() async throws {
        try await assertRenders(ShoeListView(), container: try seededContainer())
    }

    func testStrengthListRendersWithData() async throws {
        try await assertRenders(StrengthListView(), container: try seededContainer())
    }

    func testWorkoutDetailRendersWithRoute() async throws {
        let container = try seededContainer()
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Workout>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 20
        let workouts = try context.fetch(descriptor)
        let withRoute = try XCTUnwrap(workouts.first { $0.hasRoute })

        // Map + HR chart + splits table together.
        try await assertRenders(
            NavigationStack { WorkoutDetailView(workout: withRoute) },
            container: container
        )
    }

    func testStrengthSessionDetailRenders() async throws {
        let container = try seededContainer()
        let context = ModelContext(container)
        let sessions = try context.fetch(FetchDescriptor<StrengthSession>())
        let session = try XCTUnwrap(sessions.first { !$0.sets.isEmpty })

        try await assertRenders(
            NavigationStack { StrengthSessionDetailView(session: session) },
            container: container
        )
    }

    func testExerciseProgressRenders() async throws {
        let container = try seededContainer()
        let context = ModelContext(container)
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let exercise = try XCTUnwrap(exercises.first)

        try await assertRenders(
            NavigationStack { ExerciseProgressView(exercise: exercise) },
            container: container
        )
    }

    func testShoeDetailRenders() async throws {
        let container = try seededContainer()
        let context = ModelContext(container)
        let shoes = try context.fetch(FetchDescriptor<Shoe>())
        let shoe = try XCTUnwrap(shoes.first)

        try await assertRenders(
            NavigationStack { ShoeDetailView(shoe: shoe) },
            container: container
        )
    }

    // MARK: - Empty states

    func testEmptyStatesRender() async throws {
        let container = try emptyContainer()
        try await assertRenders(WorkoutListView(), container: container)
        try await assertRenders(DashboardView(), container: container)
        try await assertRenders(ShoeListView(), container: container)
        try await assertRenders(StrengthListView(), container: container)
    }

    func testRecoveryRendersWithData() async throws {
        // Exercises the readiness ring, component breakdown, and four trend charts.
        try await assertRenders(RecoveryView(), container: try seededContainer())
    }

    func testRecoveryRendersWithoutData() async throws {
        try await assertRenders(RecoveryView(), container: try emptyContainer())
    }

    func testCheckInSheetRenders() async throws {
        try await assertRenders(CheckInSheet(), container: try emptyContainer())
    }

    func testRecordsRenders() async throws {
        try await assertRenders(
            NavigationStack { RecordsView() },
            container: try seededContainer()
        )
    }

    func testRouteListRendersEmpty() async throws {
        try await assertRenders(RouteListView(), container: try emptyContainer())
    }

    func testRouteListAndDetailRenderWithData() async throws {
        let container = try emptyContainer()
        let context = ModelContext(container)
        let route = Route(name: "Vitosha loop", sport: .trailRun)
        route.setGeometry(
            coordinates: [
                CLLocationCoordinate2D(latitude: 42.60, longitude: 23.28),
                CLLocationCoordinate2D(latitude: 42.61, longitude: 23.29),
                CLLocationCoordinate2D(latitude: 42.62, longitude: 23.30),
            ],
            elevations: [900, 1100, 1350]
        )
        context.insert(route)
        try context.save()

        try await assertRenders(RouteListView(), container: container)
        try await assertRenders(
            NavigationStack { RouteDetailView(route: route) },
            container: container
        )
    }

    func testRouteBuilderRenders() async throws {
        try await assertRenders(RouteBuilderView(), container: try emptyContainer())
    }

    /// The bike and swim demo workouts exercise the power and swim sections.
    func testWorkoutDetailRendersBikeAndSwim() async throws {
        let container = try seededContainer()
        let context = ModelContext(container)
        let all = try context.fetch(FetchDescriptor<Workout>())

        let ride = try XCTUnwrap(all.first { $0.sport == .bike })
        try await assertRenders(
            NavigationStack { WorkoutDetailView(workout: ride) }, container: container)

        let swim = try XCTUnwrap(all.first { $0.sport == .swim })
        try await assertRenders(
            NavigationStack { WorkoutDetailView(workout: swim) }, container: container)
    }

    func testSettingsRenders() async throws {
        // Reads the Keychain for connection state; must render whether or not
        // any credentials happen to be present on this machine.
        try await assertRenders(SettingsView(), container: try emptyContainer())
    }

    func testPDFImportRendersEmptyState() async throws {
        try await assertRenders(PDFImportView(), container: try emptyContainer())
    }

    /// A workout with no samples must not crash the detail view.
    func testWorkoutDetailWithoutStreamsRenders() async throws {
        let container = try emptyContainer()
        let context = ModelContext(container)
        let bare = Workout(sport: .other, startedAt: .now, duration: 0,
                           distance: 0, source: "manual")
        context.insert(bare)
        try context.save()

        try await assertRenders(
            NavigationStack { WorkoutDetailView(workout: bare) },
            container: container
        )
    }
}
