import Foundation
import OSLog
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Hands a `NotificationPlan` to the system.
///
/// Thin on purpose — everything worth testing lives in `NotificationPlan`, and
/// this only exists to translate its decisions into API calls and to keep the
/// pending set in step with them.
enum NotificationScheduler {

    private static let log = Logger(subsystem: "com.slavov.fitnesstracker",
                                    category: "notifications")

    static var isAvailable: Bool {
        #if canImport(UserNotifications)
        return true
        #else
        return false
        #endif
    }

    enum Authorization: Equatable, Sendable {
        case notRequested
        case granted
        case denied
        case unavailable
    }

    static func authorization() async -> Authorization {
        #if canImport(UserNotifications)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:                    return .notRequested
        case .denied:                           return .denied
        case .authorized, .provisional, .ephemeral: return .granted
        @unknown default:                       return .notRequested
        }
        #else
        return .unavailable
        #endif
    }

    /// Ask, once. Returns whether reminders can now be delivered.
    static func requestAuthorization() async -> Bool {
        #if canImport(UserNotifications)
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            log.error("authorization request failed: \(error.localizedDescription)")
            return false
        }
        #else
        return false
        #endif
    }

    /// Replace every reminder this app owns with the given set.
    ///
    /// Replace rather than add: plans get edited, completed and deleted, and a
    /// reminder for a session that's already done is worse than no reminder.
    /// Only ids this app scheduled are removed, so nothing else is disturbed.
    @discardableResult
    static func apply(_ requests: [NotificationPlan.Request]) async -> Int {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()

        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let wanted = Set(requests.map(\.id))
        let stale = pending.filter { isOurs($0) && !wanted.contains($0) }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        var scheduled = 0
        for request in requests {
            let content = UNMutableNotificationContent()
            content.title = request.title
            content.body = request.body
            content.sound = .default

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: request.fireAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components,
                                                        repeats: false)
            do {
                try await center.add(UNNotificationRequest(
                    identifier: request.id, content: content, trigger: trigger))
                scheduled += 1
            } catch {
                log.error("couldn't schedule \(request.id): \(error.localizedDescription)")
            }
        }
        log.debug("scheduled \(scheduled) reminders, removed \(stale.count) stale")
        return scheduled
        #else
        return 0
        #endif
    }

    /// Drop every reminder this app owns, for when the athlete turns them off.
    static func cancelAll() async {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter(isOurs)
        center.removePendingNotificationRequests(withIdentifiers: ours)
        #endif
    }

    static func pendingCount() async -> Int {
        #if canImport(UserNotifications)
        return await UNUserNotificationCenter.current()
            .pendingNotificationRequests()
            .filter { isOurs($0.identifier) }
            .count
        #else
        return 0
        #endif
    }

    /// Identifiers this app scheduled, by prefix. Anything else is left alone.
    static func isOurs(_ identifier: String) -> Bool {
        ["session-", "race-", "checkin-"].contains { identifier.hasPrefix($0) }
    }
}
