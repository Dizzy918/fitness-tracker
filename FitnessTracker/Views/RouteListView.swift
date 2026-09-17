import SwiftUI
import SwiftData
import MapKit
import UniformTypeIdentifiers

struct RouteListView: View {

    @Environment(\.modelContext) private var context
    @Query(sort: \Route.createdAt, order: .reverse) private var routes: [Route]

    @State private var building = false
    @State private var importingGPX = false
    @State private var message: String?
    @State private var messageTitle = ""

    var body: some View {
        NavigationStack {
            Group {
                if routes.isEmpty {
                    ContentUnavailableView {
                        Label("No routes yet", systemImage: "map")
                    } description: {
                        Text("Plan a route on the map, or import a GPX file. Export sends it to your watch.")
                    } actions: {
                        Button("Plan a route") { building = true }
                            .buttonStyle(.borderedProminent)
                        Button("Import GPX…") { importingGPX = true }
                    }
                } else {
                    List {
                        ForEach(routes) { route in
                            NavigationLink { RouteDetailView(route: route) } label: {
                                RouteRow(route: route)
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { context.delete(routes[i]) }
                        }
                    }
                }
            }
            .navigationTitle("Routes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            building = true
                        } label: {
                            Label("Plan on map", systemImage: "map")
                        }
                        Button {
                            importingGPX = true
                        } label: {
                            Label("Import GPX…", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $building) { RouteBuilderView() }
            .fileImporter(
                isPresented: $importingGPX,
                allowedContentTypes: [Self.gpxType],
                allowsMultipleSelection: true,
                onCompletion: handleGPXImport
            )
            .alert(messageTitle, isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } }
            )) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    /// GPX has no registered system UTI on Apple platforms.
    static let gpxType: UTType = UTType(filenameExtension: "gpx") ?? .xml

    private func handleGPXImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            messageTitle = "Import failed"
            message = error.localizedDescription

        case .success(let urls):
            var added = 0
            var failures: [String] = []

            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let parsed = try GPX.parse(data: data)
                    let route = Route(
                        name: parsed.name ?? url.deletingPathExtension().lastPathComponent
                    )
                    route.setGeometry(
                        coordinates: parsed.points.map(\.coordinate),
                        elevations: parsed.points.compactMap(\.elevation)
                    )
                    context.insert(route)
                    added += 1
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            messageTitle = "GPX import"
            message = failures.isEmpty
                ? "Imported \(added) route\(added == 1 ? "" : "s")."
                : "Imported \(added). Failed:\n" + failures.joined(separator: "\n")
        }
    }
}

struct RouteRow: View {
    @Environment(\.units) private var units
    let route: Route

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: route.sport.symbolName)
                .font(.title3)
                .frame(width: 26)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.name).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if route.isLoop {
                Image(systemName: "arrow.triangle.capsulepath")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Loop route")
            }
        }
    }

    private var subtitle: String {
        var parts = [units.distance(route.distance)]
        if let gain = route.elevationGain, gain > 0 { parts.append("↑\(Int(gain)) m") }
        parts.append(route.createdAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }
}

struct RouteDetailView: View {
    @Environment(\.units) private var units
    @Environment(\.modelContext) private var context
    @Bindable var route: Route

    @State private var editing = false
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if route.coordinates.count >= 2 {
                    RouteMap(coordinates: route.coordinates)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                    StatTile(label: "Distance", value: units.distance(route.distance))
                    StatTile(label: "Elev gain", value: units.elevation(route.elevationGain))
                    StatTile(label: "Points", value: "\(route.points.count)")
                    StatTile(label: "Shape", value: route.isLoop ? "Loop" : "Point to point")
                }

                if !route.elevations.isEmpty {
                    RouteElevationProfile(
                        elevations: route.elevations,
                        coordinates: route.coordinates
                    )
                }

                // Sharing the file is how a route reaches a watch: AirDrop it, or
                // send it to the Suunto/Garmin app.
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Export GPX to watch or app", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let exportError {
                    Text(exportError).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding()
        }
        .navigationTitle(route.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = true }
            }
        }
        .sheet(isPresented: $editing) { RouteBuilderView(existing: route) }
        .task(id: route.id) { prepareExport() }
    }

    /// ShareLink needs a real file; write the GPX to a temporary one.
    private func prepareExport() {
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(route.gpxFilename)
            try route.gpx.write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
            exportError = nil
        } catch {
            exportURL = nil
            exportError = "Couldn't prepare the GPX file: \(error.localizedDescription)"
        }
    }
}

struct RouteElevationProfile: View {
    let elevations: [Double]
    let coordinates: [CLLocationCoordinate2D]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Elevation profile").font(.headline)
            ElevationChart(samples: samples)
        }
    }

    /// Reuse the workout elevation chart by expressing the route as samples.
    private var samples: [FITSample] {
        let distances = GeoMath.cumulativeDistances(coordinates)
        return elevations.enumerated().map { index, elevation in
            FITSample(
                t: Double(index), lat: nil, lon: nil, hr: nil,
                alt: elevation, speed: nil, cadence: nil,
                dist: index < distances.count ? distances[index] : nil,
                power: nil
            )
        }
    }
}
