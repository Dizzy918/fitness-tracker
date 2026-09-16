import Foundation
import SwiftData

enum FITPersistError: Error, LocalizedError {
    case duplicate
    var errorDescription: String? {
        switch self {
        case .duplicate: return "This workout was already imported."
        }
    }
}

extension FITImporter {
    /// Persist a decoded FIT workout.
    /// - Throws: `FITPersistError.duplicate` if this exact file was imported before.
    @discardableResult
    func persist(_ decoded: FITDecoded, in context: ModelContext) throws -> Workout {
        let extID = decoded.externalID
        var descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate<Workout> { $0.externalID == extID }
        )
        descriptor.fetchLimit = 1
        if try context.fetch(descriptor).first != nil {
            throw FITPersistError.duplicate
        }

        let w = Workout(
            sport: decoded.sport,
            startedAt: decoded.startedAt,
            duration: decoded.duration,
            distance: decoded.distance,
            source: "fit",
            externalID: decoded.externalID
        )
        w.avgHeartRate = decoded.avgHR
        w.maxHeartRate = decoded.maxHR
        w.elevationGain = decoded.elevationGain
        w.calories = decoded.calories
        w.avgPower = decoded.avgPower
        w.poolLength = decoded.poolLength

        let encoder = JSONEncoder()
        if !decoded.coordinates.isEmpty {
            w.polylineData = try? encoder.encode(decoded.coordinates)
        }
        if !decoded.samples.isEmpty {
            w.streamsData = try? encoder.encode(decoded.samples)
        }
        if !decoded.laps.isEmpty {
            w.lapsData = try? encoder.encode(decoded.laps)
        }

        context.insert(w)
        return w
    }
}
