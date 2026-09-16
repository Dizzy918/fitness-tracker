import Foundation
import SwiftData

@Model
final class Shoe {
    var id: UUID = UUID()
    var brand: String = ""
    var model: String = ""
    var nickname: String?
    var acquiredAt: Date = Date.distantPast
    var retiredAt: Date?
    /// User-set wear threshold in meters (default 800 km).
    var maxDistance: Double = 800_000
    var notes: String?

    /// Nullify rather than cascade: deleting a shoe must not delete runs.
    @Relationship(deleteRule: .nullify)
    var workouts: [Workout] = []

    init(
        id: UUID = UUID(),
        brand: String,
        model: String,
        nickname: String? = nil,
        acquiredAt: Date = .now,
        maxDistance: Double = 800_000
    ) {
        self.id = id
        self.brand = brand
        self.model = model
        self.nickname = nickname
        self.acquiredAt = acquiredAt
        self.maxDistance = maxDistance
    }

    /// Computed from the relationship — no denormalized counter to drift.
    var totalDistance: Double {
        workouts.reduce(0) { $0 + $1.distance }
    }

    var totalDistanceKm: Double { totalDistance / 1000 }

    /// Clamped to 1 so progress bars stay valid past the limit.
    var wearFraction: Double {
        guard maxDistance > 0 else { return 0 }
        return min(1, totalDistance / maxDistance)
    }

    var isRetired: Bool { retiredAt != nil }

    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        return "\(brand) \(model)".trimmingCharacters(in: .whitespaces)
    }
}
