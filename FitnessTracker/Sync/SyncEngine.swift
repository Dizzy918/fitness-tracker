import Foundation
import SwiftData

/// Result of one sync run, for showing the user what happened.
struct SyncReport: Sendable {
    var added: Int = 0
    var duplicates: Int = 0
    /// Activities that gained per-second data this run.
    var detailsFetched: Int = 0
    /// Activities still waiting for it, because the budget ran out.
    var detailsPending: Int = 0
    /// True when we stopped early to stay inside the provider's rate limit.
    var hitRateLimit: Bool = false
    var failures: [String] = []

    var summary: String {
        var parts = ["Added \(added)"]
        if duplicates > 0 { parts.append("skipped \(duplicates) already imported") }
        if detailsFetched > 0 { parts.append("fetched detail for \(detailsFetched)") }
        if !failures.isEmpty { parts.append("\(failures.count) failed") }
        var text = parts.joined(separator: ", ") + "."

        if detailsPending > 0 {
            text += hitRateLimit
                ? "\n\n\(detailsPending) more still need per-second data. Strava's rate limit is per 15 minutes — sync again shortly and it'll carry on."
                : "\n\n\(detailsPending) more still need per-second data. Sync again to continue."
        }
        return text
    }
}

/// Pulls activities from configured providers and persists new ones.
///
/// Dedupe is by `externalID`, which providers namespace (`strava:123`), so
/// re-syncing is always safe and the same ride from two services stays two rows
/// rather than silently overwriting one another.
@MainActor
struct SyncEngine {
    let context: ModelContext

    func providers() -> [any ActivityProvider] {
        [StravaProvider(), IntervalsICUProvider()]
    }

    /// How many per-activity detail requests one sync will spend.
    ///
    /// Streams cost one request each, and Strava's short-term budget is 200 per
    /// 15 minutes shared with everything else the app does. 25 leaves ample room
    /// for the activity list and a second sync soon after, and a first import of
    /// several hundred activities fills in over a handful of runs rather than
    /// dying at a 429 partway through the first.
    static let detailRequestsPerSync = 25

    /// Sync every configured provider. Never throws — a provider failing is
    /// recorded in the report so one bad connection can't abort the others.
    func syncAll(since: Date? = nil) async -> SyncReport {
        var report = SyncReport()
        for provider in providers() where provider.isConfigured {
            do {
                let window = since ?? defaultSince(forSource: provider.sourceIdentifier)
                let activities = try await provider.fetchActivities(since: window)
                let partial = persist(activities)
                report.added += partial.added
                report.duplicates += partial.duplicates
            } catch {
                report.failures.append(
                    "\(provider.kind.displayName): \(error.localizedDescription)"
                )
                // No point asking the same provider for streams if the list
                // call just failed on auth or a rate limit.
                if (error as? ProviderError)?.stopsTheBatch == true { continue }
            }

            guard provider.supportsStreams else { continue }
            let detail = await backfillDetail(from: provider)
            report.detailsFetched += detail.detailsFetched
            report.detailsPending += detail.detailsPending
            report.hitRateLimit = report.hitRateLimit || detail.hitRateLimit
            report.failures.append(contentsOf: detail.failures)
        }
        return report
    }

    /// Fill in per-second data for activities that don't have it yet.
    ///
    /// Newest first: recent training is what you actually look at, and a partial
    /// backfill that covers this month is far more useful than one that starts
    /// from a year ago and never reaches the present.
    @discardableResult
    func backfillDetail(from provider: any ActivityProvider,
                        limit: Int = SyncEngine.detailRequestsPerSync) async -> SyncReport {
        var report = SyncReport()
        let pending = workoutsNeedingDetail(source: provider.sourceIdentifier)
        guard !pending.isEmpty else { return report }

        // Spend at most what the provider's published budget allows.
        let affordable = provider.rateLimitBudget.map { $0.affordableRequests() } ?? limit
        let allowance = max(0, min(limit, affordable))
        if allowance == 0 {
            report.detailsPending = pending.count
            report.hitRateLimit = true
            return report
        }

        var spent = 0
        for workout in pending {
            guard spent < allowance else { break }
            guard let externalID = workout.externalID else { continue }
            spent += 1

            do {
                let detail = try await provider.fetchDetail(externalID: externalID)
                apply(detail, to: workout)
                if !detail.isEmpty { report.detailsFetched += 1 }
            } catch let error as ProviderError where error.stopsTheBatch {
                report.hitRateLimit = true
                break
            } catch {
                // A single activity failing — deleted, private, a 404 — must not
                // stop the rest. Mark it so the next sync doesn't retry forever.
                workout.detailFetchedAt = .now
                report.failures.append(
                    "\(provider.kind.displayName) detail for \(externalID): \(error.localizedDescription)"
                )
            }
        }

        report.detailsPending = max(0, pending.count - spent)
        return report
    }

    /// Synced workouts with no per-second data and no record of having asked.
    func workoutsNeedingDetail(source: String, limit: Int = 500) -> [Workout] {
        var descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate {
                $0.source == source && $0.detailFetchedAt == nil && $0.streamsData == nil
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Write fetched detail onto a workout.
    ///
    /// Always stamps `detailFetchedAt`, including when the provider had nothing
    /// to give — that's the whole point of the marker.
    func apply(_ detail: ActivityDetail, to workout: Workout) {
        workout.detailFetchedAt = .now
        guard !detail.isEmpty else { return }

        if !detail.samples.isEmpty {
            workout.streamsData = try? JSONEncoder().encode(detail.samples)
        }
        // The full track beats the decimated summary polyline we already have.
        if !detail.coordinates.isEmpty {
            workout.polylineData = try? JSONEncoder().encode(detail.coordinates)
        }
    }

    /// How far back to fetch, **per provider**.
    ///
    /// The watermark has to be scoped to the source being synced. Keying it off
    /// "anything not manual" meant a `.fit` import from this morning — or the
    /// demo seeder, which the README tells you to run first — set the window for
    /// Strava's *first ever* sync to one day, so it imported almost nothing and
    /// gave no hint why.
    func defaultSince(forSource source: String) -> Date {
        var descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate { $0.source == source },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        if let newest = try? context.fetch(descriptor).first {
            // A day of overlap absorbs activities edited after they were synced.
            return newest.startedAt.addingTimeInterval(-86400)
        }
        return Self.firstSyncWindow()
    }

    /// Nothing from this provider yet, so pull a full year of history.
    static func firstSyncWindow(from now: Date = .now) -> Date {
        Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now
    }

    @discardableResult
    func persist(_ activities: [RemoteActivity]) -> SyncReport {
        var report = SyncReport()
        for activity in activities {
            if exists(externalID: activity.externalID) {
                report.duplicates += 1
                continue
            }
            let workout = Workout(
                sport: activity.sport,
                startedAt: activity.startedAt,
                duration: activity.duration,
                distance: activity.distance,
                source: activity.source,
                externalID: activity.externalID
            )
            workout.avgHeartRate = activity.avgHeartRate
            workout.maxHeartRate = activity.maxHeartRate
            workout.elevationGain = activity.elevationGain
            workout.calories = activity.calories
            workout.notes = activity.name
            if !activity.coordinates.isEmpty {
                workout.polylineData = try? JSONEncoder().encode(activity.coordinates)
            }
            context.insert(workout)
            report.added += 1
        }
        return report
    }

    func exists(externalID: String) -> Bool {
        var descriptor = FetchDescriptor<Workout>(
            predicate: #Predicate { $0.externalID == externalID }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first) != nil
    }
}
