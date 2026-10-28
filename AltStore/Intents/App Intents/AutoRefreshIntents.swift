//
//  AutoRefreshIntents.swift
//  AltStore
//
//  Tunnel-aware "Smart Refresh" shortcut and the 48 hour expiration warning.
//
//  Needs proper testing on device (Shortcuts timeouts, launching LocalDevVPN, notification actions in the background).
//

import AppIntents
import CoreData
import Network
import UIKit
import UserNotifications

// MARK: - Shared coordinator

enum AutoRefreshCoordinator {
    /// How long we wait for LocalDevVPN / the local tunnel before giving up.
    static let tunnelWaitTimeout: TimeInterval = 5

    struct AppExpiry: Sendable {
        let name: String
        let bundleIdentifier: String
        let expirationDate: Date

        var remaining: TimeInterval { expirationDate.timeIntervalSinceNow }
    }

    // MARK: Tunnel pre-check

    /// Probes the local tunnel (see `PairingRecoveryService`) and waits up to `tunnelWaitTimeout` seconds for it to come up.
    /// When `launchIfNeeded` is set, LocalDevVPN is asked to start through its URL scheme (only possible while SideStore is in the foreground).
    static func ensureTunnelReady(launchIfNeeded: Bool) async -> Bool {
        let service = PairingRecoveryService.shared
        if service.probeTunnel() != .disconnected { return true }

        if launchIfNeeded {
            await openTunnelApp()
        }

        let deadline = Date().addingTimeInterval(tunnelWaitTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if service.probeTunnel() != .disconnected { return true }
        }
        return false
    }

    @MainActor
    private static func openTunnelApp() async {
        guard UIApplication.shared.applicationState == .active else {
            debugLog("[AutoRefresh] App is not in the foreground. Cannot launch LocalDevVPN through its URL scheme.")
            return
        }
        _ = await PairingRecoveryService.shared.openLocalDevVPN()
    }

    // MARK: Refresh

    static func refreshAllApps(presentsStandardNotification: Bool,
                               progress: Progress?) async throws -> [String: Result<InstalledApp, Error>]
    {
        try await DatabaseManager.shared.start()

        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let installedApps = await context.perform { InstalledApp.fetchAppsForRefreshingAll(in: context) }

        return try await withCheckedThrowingContinuation { continuation in
            let operation: BackgroundRefreshAppsOperation
            do {
                operation = try AppManager.shared.backgroundRefresh(installedApps, presentsNotifications: presentsStandardNotification) { result in
                    continuation.resume(with: result)
                }
            } catch {
                continuation.resume(throwing: error)
                return
            }

            operation.ignoresServerNotFoundError = false
            progress?.addChild(operation.progress, withPendingUnitCount: 1)
        }
    }

    // MARK: Expiry information

    static func installedAppExpiries() async -> [AppExpiry] {
        do {
            try await DatabaseManager.shared.start()
        } catch {
            debugLog("[AutoRefresh] Database could not be started: \(error)")
            return []
        }

        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        return await context.perform {
            let request = InstalledApp.fetchRequest() as NSFetchRequest<InstalledApp>
            let apps = (try? context.fetch(request)) ?? []
            return apps
                .filter { $0.isActive }
                .map { AppExpiry(name: $0.name, bundleIdentifier: $0.bundleIdentifier, expirationDate: $0.expirationDate) }
                .sorted { $0.expirationDate < $1.expirationDate }
        }
    }

    private static func remainingText(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return NSLocalizedString("expired", comment: "") }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        let text = formatter.string(from: interval) ?? ""
        return String(format: NSLocalizedString("%@ left", comment: ""), text)
    }

    static func summaryLines(for expiries: [AppExpiry]) -> String {
        expiries
            .map { "\($0.name): \(remainingText($0.remaining))" }
            .joined(separator: "\n")
    }

    // MARK: Notifications

    static func postNotification(identifier: String, title: String, body: String, categoryIdentifier: String? = nil) async {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            debugLog("[AutoRefresh] Failed to post notification '\(identifier)': \(error)")
        }
    }

    /// Posts a local notification with the remaining days of every installed app after a refresh.
    @discardableResult
    static func postRefreshSummary(results: [String: Result<InstalledApp, Error>]) async -> (refreshed: Int, failed: Int) {
        var failed = 0
        for (_, result) in results {
            if case .failure = result { failed += 1 }
        }
        let refreshed = results.count - failed

        let expiries = await installedAppExpiries()
        let title = failed == 0
            ? NSLocalizedString("Apps Refreshed", comment: "")
            : String(format: NSLocalizedString("Refreshed with %d failure(s)", comment: ""), failed)

        await postNotification(identifier: "smart-refresh-summary",
                               title: title,
                               body: summaryLines(for: expiries))
        return (refreshed, failed)
    }
}

// MARK: - Smart Refresh intent

@available(iOS 17.0, tvOS 17.0, *)
struct SmartRefreshAllAppsIntent: AppIntent, ProgressReportingIntent
{
    static var title: LocalizedStringResource = "Smart Refresh All Apps"
    static var description = IntentDescription("Checks that the local tunnel is up (waiting up to 5 seconds), refreshes all apps and sends a summary with the remaining days of every app.")

    @Parameter(title: "Try to Start LocalDevVPN", default: true)
    var launchTunnelIfNeeded: Bool

    @Parameter(title: "Send Summary Notification", default: true)
    var sendSummary: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Smart refresh all apps") {
            \.$launchTunnelIfNeeded
            \.$sendSummary
        }
    }

    init()
    {
        self.progress.completedUnitCount = 0
        self.progress.totalUnitCount = 1
    }

    func perform() async throws -> some IntentResult & ProvidesDialog
    {
        do
        {
            try await DatabaseManager.shared.start()

            // Do not blindly start a refresh without a tunnel, it would only fail with a connection error.
            let isTunnelReady = await AutoRefreshCoordinator.ensureTunnelReady(launchIfNeeded: self.launchTunnelIfNeeded)
            guard isTunnelReady else {
                throw OperationError.noVPN(reason: NSLocalizedString("The local tunnel was not ready within 5 seconds. Enable LocalDevVPN and run the shortcut again.", comment: ""))
            }

            let results = try await AutoRefreshCoordinator.refreshAllApps(presentsStandardNotification: false,
                                                                          progress: self.progress)

            let counts: (refreshed: Int, failed: Int)
            if self.sendSummary {
                counts = await AutoRefreshCoordinator.postRefreshSummary(results: results)
            } else {
                let failed = results.values.filter { if case .failure = $0 { return true } else { return false } }.count
                counts = (results.count - failed, failed)
            }

            await ExpirationWarningManager.shared.evaluate()

            let text = counts.failed == 0
                ? String(format: NSLocalizedString("Refreshed %d app(s).", comment: ""), counts.refreshed)
                : String(format: NSLocalizedString("Refreshed %d app(s), %d failed.", comment: ""), counts.refreshed, counts.failed)
            return .result(dialog: "\(text)")
        }
        catch
        {
            throw IntentError(error)
        }
    }
}

// MARK: - Expiration warning

final class ExpirationWarningManager: @unchecked Sendable {
    static let shared = ExpirationWarningManager()

    static let categoryIdentifier = "io.sidestore.expiration-warning"
    static let refreshActionIdentifier = "io.sidestore.expiration-warning.refresh"

    /// Apps expiring within this window trigger a warning.
    private let warningWindow: TimeInterval = 48 * 60 * 60
    /// Do not nag more often than this.
    private let minimumNotificationInterval: TimeInterval = 6 * 60 * 60
    private let lastNotifiedKey = "lastExpirationWarningDate"
    private let notificationIdentifier = "expiration-warning"

    private init() {}

    func registerNotificationCategory() {
        let refreshAction = UNNotificationAction(identifier: Self.refreshActionIdentifier,
                                                 title: NSLocalizedString("Refresh Now", comment: ""),
                                                 options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.categoryIdentifier,
                                              actions: [refreshAction],
                                              intentIdentifiers: [],
                                              options: [])

        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            var categories = existing.filter { $0.identifier != Self.categoryIdentifier }
            categories.insert(category)
            center.setNotificationCategories(categories)
        }
    }

    /// Posts a time sensitive warning with a "Refresh Now" action when any app has less than 48 hours left
    /// and the device is on Wi-Fi.
    func evaluate() async {
        guard UserDefaults.standard.isExpirationWarningEnabled else { return }
        guard await Self.isOnWiFi() else { return }

        if let last = UserDefaults.standard.object(forKey: lastNotifiedKey) as? Date,
           Date().timeIntervalSince(last) < minimumNotificationInterval
        {
            return
        }

        let expiring = await AutoRefreshCoordinator.installedAppExpiries()
            .filter { $0.remaining < warningWindow }
        guard !expiring.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Apps Expiring Soon", comment: "")
        content.body = AutoRefreshCoordinator.summaryLines(for: expiring)
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        #if !os(tvOS)
        // Falls back to a normal alert when the Time Sensitive entitlement is not part of the signing profile.
        content.interruptionLevel = .timeSensitive
        #endif

        let request = UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            UserDefaults.standard.set(Date(), forKey: lastNotifiedKey)
        } catch {
            debugLog("[ExpirationWarning] Failed to post warning: \(error)")
        }
    }

    /// Handles taps on the warning or its action button. Returns `true` if the response belonged to this manager.
    func handleNotificationResponse(_ response: UNNotificationResponse) async -> Bool {
        guard response.notification.request.content.categoryIdentifier == Self.categoryIdentifier else { return false }

        switch response.actionIdentifier {
        case Self.refreshActionIdentifier, UNNotificationDefaultActionIdentifier:
            await performQuickRefresh()
        default:
            break
        }
        return true
    }

    func performQuickRefresh() async {
        let isTunnelReady = await AutoRefreshCoordinator.ensureTunnelReady(launchIfNeeded: true)
        guard isTunnelReady else {
            await AutoRefreshCoordinator.postNotification(
                identifier: "smart-refresh-summary",
                title: NSLocalizedString("Refresh Skipped", comment: ""),
                body: NSLocalizedString("The local tunnel is not connected. Enable LocalDevVPN and try again.", comment: "")
            )
            return
        }

        do {
            let results = try await AutoRefreshCoordinator.refreshAllApps(presentsStandardNotification: false, progress: nil)
            await AutoRefreshCoordinator.postRefreshSummary(results: results)
        } catch {
            await AutoRefreshCoordinator.postNotification(
                identifier: "smart-refresh-summary",
                title: NSLocalizedString("Failed to Refresh Apps", comment: ""),
                body: error.localizedDescription
            )
        }
    }

    // MARK: Wi-Fi detection

    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        /// Returns `true` only for the first caller.
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return false }
            done = true
            return true
        }
    }

    private static func isOnWiFi() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            let queue = DispatchQueue(label: "io.sidestore.expiration-warning.wifi")
            let gate = OneShot()

            let finish: @Sendable (Bool) -> Void = { value in
                guard gate.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: value)
            }

            monitor.pathUpdateHandler = { path in
                finish(path.status == .satisfied)
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.5) { finish(false) }
        }
    }
}
