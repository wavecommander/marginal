import BackgroundTasks
import UIKit
import UserNotifications

/// Keeps one marked-up PDF export running when Tactile Texts leaves the foreground, from the
/// moment it starts until it finishes (design: "Export Marked-Up PDF", *Running in the
/// background*).
///
/// - iPadOS 26 and later: a continued processing task (`BGContinuedProcessingTask`), which the
///   system shows with the export's progress and which the user can stop there (that cancels the
///   export, as Cancel does). Its identifier is `continuedTaskPrefix` plus a UUID, one of the
///   wildcard `BGTaskSchedulerPermittedIdentifiers` in `project.yml`.
/// - Always (and the only help before iPadOS 26, or when the system will not run the task now):
///   a UIKit background task, about half a minute. When that runs out the app is suspended and
///   the export carries on when Tactile Texts is opened again.
@MainActor
final class MarkedUpExportBackgroundRun {
    /// `BGTaskSchedulerPermittedIdentifiers` lists `software.tactile.texts.export.*`.
    static let continuedTaskPrefix = "software.tactile.texts.export."

    private var assertion: UIBackgroundTaskIdentifier = .invalid
    /// The running `BGContinuedProcessingTask` (iPadOS 26+), once the system has started it.
    private var continuedTask: BGTask?
    private var fraction: Double = 0
    private var finished = false
    private let onExpire: @MainActor () -> Void

    /// - Parameters:
    ///   - title, subtitle: what the system shows for a continued processing task.
    ///   - onExpire: the system stopped the task (the user did, or it ran out of time): cancel
    ///     the export.
    init(title: String, subtitle: String, onExpire: @escaping @MainActor () -> Void) {
        self.onExpire = onExpire
        assertion = UIApplication.shared.beginBackgroundTask(withName: "Marked-up PDF export") { [weak self] in
            MainActor.assumeIsolated { self?.endAssertion() }
        }
        if #available(iOS 26.0, *) {
            submitContinuedTask(title: title, subtitle: subtitle)
        }
    }

    /// How far the export has got, for the system's progress display.
    func update(fraction: Double) {
        self.fraction = fraction
        reportProgress()
    }

    /// The export finished, failed or was cancelled.
    func end(success: Bool) {
        guard !finished else { return }
        finished = true
        if let continuedTask {
            reportProgress()
            continuedTask.setTaskCompleted(success: success)
            self.continuedTask = nil
        }
        endAssertion()
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }

    private func reportProgress() {
        guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64((min(max(fraction, 0), 1) * 1000).rounded())
    }

    @available(iOS 26.0, *)
    private func submitContinuedTask(title: String, subtitle: String) {
        let identifier = Self.continuedTaskPrefix + UUID().uuidString
        // Continued processing tasks may be registered after launch; each identifier is new, so
        // it is registered once. The main queue, so the handler runs on the main actor.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, !self.finished else {
                    task.setTaskCompleted(success: true)
                    return
                }
                self.attach(task)
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // Now or not at all: the export is already running in the app.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The simulator, Low Power Mode or a busy system: the UIKit background task is left.
        }
    }

    private func attach(_ task: BGTask) {
        continuedTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expire() }
        }
        reportProgress()
    }

    private func expire() {
        guard !finished else { return }
        finished = true
        continuedTask?.setTaskCompleted(success: false)
        continuedTask = nil
        endAssertion()
        onExpire()
    }
}

// MARK: - Notifications

/// The notification posted when an export finishes, or fails, while it runs in the background.
@MainActor
enum MarkedUpExportNotifications {
    /// Posted (on the main actor) when the user opens one of these notifications; `object` is the
    /// notification's identifier.
    static let opened = Notification.Name("MarkedUpExportNotificationOpened")

    /// Asks once for permission to notify (the system asks the user the first time only).
    static func requestAuthorization() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    static func post(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    static func remove(identifier: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Shows these notifications while Tactile Texts is open too, and passes on taps. Set once at
    /// launch (`TactileTextsApp.init`).
    static func install() {
        UNUserNotificationCenter.current().delegate = MarkedUpExportNotificationDelegate.shared
    }
}

private final class MarkedUpExportNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = MarkedUpExportNotificationDelegate()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        await MainActor.run {
            NotificationCenter.default.post(name: MarkedUpExportNotifications.opened, object: identifier)
        }
    }
}

// MARK: - Time left

/// How long a running export has left, from how long it has run and how far it has got.
nonisolated enum MarkedUpExportTimeEstimate {
    /// Seconds left, or `nil` until there is enough to go on (5% done and 2 seconds in).
    static func remaining(elapsed: TimeInterval, fraction: Double) -> TimeInterval? {
        guard fraction >= 0.05, fraction < 1, elapsed >= 2 else { return nil }
        return elapsed * (1 - fraction) / fraction
    }

    /// "About 3 minutes left" and the like.
    static func text(remaining: TimeInterval?) -> String {
        guard let remaining else { return "Working out how long this will take…" }
        switch remaining {
        case ..<45:
            return "Less than a minute left"
        case ..<90:
            return "About a minute left"
        case ..<3570:
            return "About \(Int((remaining / 60).rounded())) minutes left"
        default:
            let minutes = Int((remaining / 60).rounded())
            let hours = minutes / 60, rest = minutes % 60
            let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
            return rest == 0 ? "About \(hourText) left" : "About \(hourText) \(rest) min left"
        }
    }
}
