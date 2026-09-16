import SwiftUI
import SwiftData

struct ShoeListView: View {
    /// True when pushed from the Dashboard: the parent already owns a
    /// NavigationStack, and nesting one breaks the title and back button.
    var embedded = true

    @Environment(\.modelContext) private var context
    @Query(sort: \Shoe.acquiredAt, order: .reverse) private var shoes: [Shoe]
    @State private var showAdd = false

    private var active: [Shoe] { shoes.filter { !$0.isRetired } }
    private var retired: [Shoe] { shoes.filter(\.isRetired) }

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
                if shoes.isEmpty {
                    ContentUnavailableView {
                        Label("No shoes yet", systemImage: "shoe")
                    } description: {
                        Text("Add a pair to track mileage and get wear warnings.")
                    } actions: {
                        Button("Add shoe") { showAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section("Active") {
                            ForEach(active) { shoe in
                                NavigationLink { ShoeDetailView(shoe: shoe) } label: {
                                    ShoeRow(shoe: shoe)
                                }
                            }
                            .onDelete { delete(active, at: $0) }
                        }
                        if !retired.isEmpty {
                            Section("Retired") {
                                ForEach(retired) { shoe in
                                    NavigationLink { ShoeDetailView(shoe: shoe) } label: {
                                        ShoeRow(shoe: shoe)
                                    }
                                }
                                .onDelete { delete(retired, at: $0) }
                            }
                        }
                    }
                }
            }
        .navigationTitle("Shoes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Label("Add", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) { AddShoeSheet() }
    }

    private func delete(_ list: [Shoe], at offsets: IndexSet) {
        for i in offsets { context.delete(list[i]) }
    }
}

struct ShoeRow: View {
    let shoe: Shoe

    private var tint: Color {
        switch shoe.wearFraction {
        case ..<0.65: return .green
        case ..<0.85: return .orange
        default:      return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(shoe.displayName)
                    .font(.headline)
                    .strikethrough(shoe.isRetired)
                Spacer()
                Text(String(format: "%.0f km", shoe.totalDistanceKm))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: shoe.wearFraction).tint(tint)
            HStack {
                Text("\(shoe.workouts.count) runs")
                Spacer()
                Text("limit \(Int(shoe.maxDistance / 1000)) km")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

struct ShoeDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var shoe: Shoe

    private var runs: [Workout] {
        shoe.workouts.sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Distance", value: String(format: "%.1f km", shoe.totalDistanceKm))
                LabeledContent("Wear", value: "\(Int(shoe.wearFraction * 100))%")
                LabeledContent("Runs", value: "\(shoe.workouts.count)")
                LabeledContent("Acquired",
                               value: shoe.acquiredAt.formatted(date: .abbreviated, time: .omitted))
                if let retiredAt = shoe.retiredAt {
                    LabeledContent("Retired",
                                   value: retiredAt.formatted(date: .abbreviated, time: .omitted))
                }
            }

            Section("Wear limit") {
                Stepper("\(Int(shoe.maxDistance / 1000)) km",
                        value: Binding(
                            get: { shoe.maxDistance / 1000 },
                            set: { shoe.maxDistance = $0 * 1000 }
                        ),
                        in: 200...1500, step: 50)
            }

            Section {
                if shoe.isRetired {
                    Button("Un-retire") { shoe.retiredAt = nil }
                } else {
                    Button("Retire this pair", role: .destructive) { shoe.retiredAt = .now }
                }
            }

            Section("Runs") {
                if runs.isEmpty {
                    Text("No runs assigned yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(runs) { run in
                        NavigationLink { WorkoutDetailView(workout: run) } label: {
                            HStack {
                                Text(run.startedAt.formatted(date: .abbreviated, time: .omitted))
                                Spacer()
                                Text(Fmt.km(run.distance)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(shoe.displayName)
    }
}

struct AddShoeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var brand = ""
    @State private var model = ""
    @State private var nickname = ""
    @State private var maxKm: Double = 800

    var body: some View {
        NavigationStack {
            Form {
                TextField("Brand", text: $brand)
                TextField("Model", text: $model)
                TextField("Nickname (optional)", text: $nickname)
                Stepper("Wear limit: \(Int(maxKm)) km", value: $maxKm, in: 200...1500, step: 50)
            }
            .navigationTitle("Add Shoe")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        context.insert(Shoe(
                            brand: brand.trimmingCharacters(in: .whitespaces),
                            model: model.trimmingCharacters(in: .whitespaces),
                            nickname: nickname.isEmpty ? nil : nickname,
                            maxDistance: maxKm * 1000
                        ))
                        dismiss()
                    }
                    .disabled(brand.isEmpty || model.isEmpty)
                }
            }
        }
    }
}
