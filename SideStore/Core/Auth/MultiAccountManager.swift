//
//  MultiAccountManager.swift
//  SideStore
//
//  Apple ID account pool with per-account App ID quota tracking.
//
//  Credentials (password, tokens, signing certificate) live in the Keychain, the quota is derived from the
//  `AppID` / `Team` CoreData entities (the portal's own list, synced by `SyncAppIDsOperation`) and snapshotted
//  into the pool index so it is still known while another account is active.
//
//  Needs proper testing with real free accounts (token expiry, 2FA, certificate limits per team).
//

@preconcurrency import UIKit
import Foundation
import CoreData
import SideSign

// MARK: - Errors

enum MultiAccountError: LocalizedError {
    /// Thrown by the provisioning step when the portal refused to register more App IDs for a free team.
    case appIDQuotaExceeded(teamIdentifier: String, underlying: Error)
    case unknownAccount(String)
    case missingCredentials(String)
    case accountNotInDatabase(String)
    case databaseUnavailable
    case cannotRemoveActiveAccount
    case noAvailableAccount

    var errorDescription: String? {
        switch self {
        case .appIDQuotaExceeded(_, let underlying):
            return underlying.localizedDescription
        case .unknownAccount(let appleID):
            return String(format: NSLocalizedString("%@ is not part of the account pool.", comment: ""), appleID)
        case .missingCredentials(let appleID):
            return String(format: NSLocalizedString("Stored credentials for %@ are missing. Add the account again.", comment: ""), appleID)
        case .accountNotInDatabase(let appleID):
            return String(format: NSLocalizedString("%@ has not completed sign-in on this device yet. Add the account again.", comment: ""), appleID)
        case .databaseUnavailable:
            return NSLocalizedString("The database is not ready yet.", comment: "")
        case .cannotRemoveActiveAccount:
            return NSLocalizedString("The active account cannot be removed. Switch to another account first.", comment: "")
        case .noAvailableAccount:
            return NSLocalizedString("No backup Apple ID with free App ID slots is available.", comment: "")
        }
    }
}

// MARK: - Models

struct PoolAccount: Codable, Identifiable, Equatable, Sendable {
    var appleID: String
    var accountIdentifier: String?
    var teamIdentifier: String?
    var teamName: String?
    var isFreeTeam: Bool = true
    var appIDsUsed: Int = 0
    /// Earliest expiration date among the team's registered App IDs: the moment a slot frees up again.
    var quotaResetDate: Date?
    var lastUpdated: Date?
    var addedDate: Date = Date()

    var id: String { appleID.lowercased() }

    /// Number of App IDs that can still be registered. Paid teams are treated as unlimited.
    func remainingAppIDs(now: Date = Date()) -> Int {
        guard isFreeTeam else { return Int.max }
        if appIDsUsed >= Team.maximumFreeAppIDs, let reset = quotaResetDate, reset <= now {
            return 1    // at least the oldest App ID has expired by now
        }
        return max(0, Team.maximumFreeAppIDs - appIDsUsed)
    }

    func isExhausted(now: Date = Date()) -> Bool {
        remainingAppIDs(now: now) == 0
    }
}

private struct PoolCredentials: Codable {
    var password: String?
    var adsid: String?
    var xcodeToken: String?
    var signingCertificateP12: Data?
    var signingCertificatePassword: String?
}

private struct ActiveAccountInfo: Sendable {
    let accountIdentifier: String
    let teamIdentifier: String
    let teamName: String
    let isFreeTeam: Bool
    let appIDsUsed: Int
    let quotaResetDate: Date?
}

// MARK: - Manager

final class MultiAccountManager: @unchecked Sendable {
    static let shared = MultiAccountManager()

    static let poolDidChangeNotification = Notification.Name("MultiAccountManager.poolDidChange")

    private let indexKey = "accountPool.index"
    private let credentialsKeyPrefix = "accountPool.cred."
    private let lock = NSLock()

    private init() {}

    // MARK: Pool storage

    var accounts: [PoolAccount] {
        lock.withLock { loadIndex() }
    }

    func account(for appleID: String) -> PoolAccount? {
        let key = appleID.lowercased()
        return self.accounts.first { $0.id == key }
    }

    var activeAppleID: String? {
        AuthManager.shared.currentAppleID
    }

    var isAutoRotateEnabled: Bool {
        UserDefaults.standard.isAccountPoolAutoRotateEnabled
    }

    private func loadIndex() -> [PoolAccount] {
        guard let data = Keychain.shared[dynamicKey: indexKey],
              let list = try? JSONDecoder().decode([PoolAccount].self, from: data) else { return [] }
        return list
    }

    private func saveIndex(_ list: [PoolAccount]) {
        Keychain.shared[dynamicKey: indexKey] = try? JSONEncoder().encode(list)
    }

    private func mutateIndex(_ body: (inout [PoolAccount]) -> Void) {
        lock.withLock {
            var list = loadIndex()
            let before = list
            body(&list)
            guard list != before else { return }
            saveIndex(list)
        }
        NotificationCenter.default.post(name: Self.poolDidChangeNotification, object: nil)
    }

    private func upsert(_ account: PoolAccount) {
        mutateIndex { list in
            if let index = list.firstIndex(where: { $0.id == account.id }) {
                list[index] = account
            } else {
                list.append(account)
            }
        }
    }

    private func credentials(for account: PoolAccount) -> PoolCredentials? {
        guard let data = Keychain.shared[dynamicKey: credentialsKeyPrefix + account.id] else { return nil }
        return try? JSONDecoder().decode(PoolCredentials.self, from: data)
    }

    private func store(_ credentials: PoolCredentials, for account: PoolAccount) {
        Keychain.shared[dynamicKey: credentialsKeyPrefix + account.id] = try? JSONEncoder().encode(credentials)
    }

    func removeAccount(appleID: String) throws {
        guard self.activeAppleID?.lowercased() != appleID.lowercased() else {
            throw MultiAccountError.cannotRemoveActiveAccount
        }
        let key = appleID.lowercased()
        Keychain.shared[dynamicKey: credentialsKeyPrefix + key] = nil
        mutateIndex { $0.removeAll { $0.id == key } }
    }

    // MARK: Quota

    /// Called with the portal's current App ID list (see `FetchProvisioningProfilesOperation`).
    func recordUsage(teamIdentifier: String, appIDs: [ALTAppID]) {
        let reset = appIDs.compactMap { $0.expirationDate }.min()
        mutateIndex { list in
            guard let index = list.firstIndex(where: { $0.teamIdentifier == teamIdentifier }) else { return }
            list[index].appIDsUsed = appIDs.count
            list[index].quotaResetDate = reset
            list[index].lastUpdated = Date()
        }
    }

    private func markExhausted(teamIdentifier: String) {
        mutateIndex { list in
            guard let index = list.firstIndex(where: { $0.teamIdentifier == teamIdentifier }), list[index].isFreeTeam else { return }
            if list[index].appIDsUsed < Team.maximumFreeAppIDs {
                list[index].appIDsUsed = Team.maximumFreeAppIDs
            }
            list[index].lastUpdated = Date()
        }
    }

    /// Re-reads the quota of every pooled account from the `AppID` CoreData entities.
    func refreshQuotaFromDatabase() async {
        guard DatabaseManager.shared.isStarted else { return }
        let pool = self.accounts
        let teamIdentifiers = pool.compactMap { $0.teamIdentifier }
        guard !teamIdentifiers.isEmpty else { return }

        let usage: [String: (count: Int, reset: Date?)] = await DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
            var result: [String: (count: Int, reset: Date?)] = [:]
            for identifier in teamIdentifiers {
                guard let team = Team.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(Team.identifier), identifier), in: context) else { continue }
                let request = AppID.fetchRequest() as NSFetchRequest<AppID>
                request.predicate = NSPredicate(format: "%K == %@", #keyPath(AppID.team), team)
                let appIDs = (try? context.fetch(request)) ?? []
                result[identifier] = (appIDs.count, appIDs.compactMap { $0.expirationDate }.min())
            }
            return result
        }

        mutateIndex { list in
            for index in list.indices {
                guard let identifier = list[index].teamIdentifier, let entry = usage[identifier] else { continue }
                list[index].appIDsUsed = entry.count
                list[index].quotaResetDate = entry.reset
                list[index].lastUpdated = Date()
            }
        }
    }

    private func readActiveAccountInfo() async -> ActiveAccountInfo? {
        guard DatabaseManager.shared.isStarted else { return nil }
        return await DatabaseManager.shared.persistentContainer.performBackgroundTask { context -> ActiveAccountInfo? in
            guard let account = DatabaseManager.shared.activeAccount(in: context),
                  let team = DatabaseManager.shared.activeTeam(in: context) else { return nil }

            let request = AppID.fetchRequest() as NSFetchRequest<AppID>
            request.predicate = NSPredicate(format: "%K == %@", #keyPath(AppID.team), team)
            let appIDs = (try? context.fetch(request)) ?? []

            return ActiveAccountInfo(accountIdentifier: account.identifier,
                                     teamIdentifier: team.identifier,
                                     teamName: team.name,
                                     isFreeTeam: team.type == .free,
                                     appIDsUsed: appIDs.count,
                                     quotaResetDate: appIDs.compactMap { $0.expirationDate }.min())
        }
    }

    // MARK: Snapshot of the active account

    /// Stores the currently active account (credentials, signing certificate, quota) in the pool.
    @discardableResult
    func snapshotActiveAccount() async -> PoolAccount? {
        let auth = AuthManager.shared
        guard auth.isAuthenticated, let appleID = auth.currentAppleID else { return nil }

        var entry = self.account(for: appleID) ?? PoolAccount(appleID: appleID)
        if let info = await self.readActiveAccountInfo() {
            entry.accountIdentifier = info.accountIdentifier
            entry.teamIdentifier = info.teamIdentifier
            entry.teamName = info.teamName
            entry.isFreeTeam = info.isFreeTeam
            entry.appIDsUsed = info.appIDsUsed
            entry.quotaResetDate = info.quotaResetDate
            entry.lastUpdated = Date()
        }

        let credentials = PoolCredentials(password: auth.password,
                                          adsid: auth.adsid,
                                          xcodeToken: auth.xcodeToken,
                                          signingCertificateP12: Keychain.shared.signingCertificate,
                                          signingCertificatePassword: Keychain.shared.signingCertificatePassword)
        self.store(credentials, for: entry)
        self.upsert(entry)
        return entry
    }

    // MARK: Adding accounts

    /// Signs in a backup Apple ID through the regular (interactive) flow and adds it to the pool.
    /// The previously active account stays the default signing account.
    @MainActor
    func addAccount(presenting viewController: UIViewController) async throws {
        let previous = await self.snapshotActiveAccount()
        let previousCredentials = previous.flatMap { self.credentials(for: $0) }

        // The sign-in flow treats an active certificate that does not belong to the new team as a custom certificate
        // and would keep using it, so detach the previous account's certificate first (it is kept in the pool snapshot).
        if previous != nil {
            CertificateManager.shared.clearActiveCertificate()
        }

        do {
            let result = try await AuthManager.shared.signIn(presentingViewController: viewController,
                                                             skipResign: true,
                                                             skipHowTos: true)
            await self.snapshotActiveAccount()

            if let previous, let previousCredentials, previous.teamIdentifier != result.team.identifier {
                try await self.applyLocally(previous, credentials: previousCredentials)
            }
        } catch {
            if let previous, let previousCredentials {
                try? await self.applyLocally(previous, credentials: previousCredentials)
            }
            throw error
        }
    }

    // MARK: Switching accounts

    /// Makes `appleID` the active signing account. Uses the stored tokens first and falls back to a silent
    /// password sign-in when the tokens are no longer accepted.
    func switchActiveAccount(to appleID: String) async throws {
        guard let target = self.account(for: appleID) else {
            throw MultiAccountError.unknownAccount(appleID)
        }
        guard let targetCredentials = self.credentials(for: target) else {
            throw MultiAccountError.missingCredentials(appleID)
        }
        if AuthManager.shared.isAuthenticated,
           AuthManager.shared.currentAppleID?.lowercased() == target.id {
            return
        }

        let previous = await self.snapshotActiveAccount()
        let previousCredentials = previous.flatMap { self.credentials(for: $0) }

        do {
            try await self.applyLocally(target, credentials: targetCredentials)

            if !(await self.activeSessionIsValid()) {
                debugLog("[MultiAccountManager] Stored tokens for \(target.appleID) were rejected. Falling back to silent sign-in...")
                try await self.silentSignIn(target, credentials: targetCredentials)
            }

            // register the device on the new team when needed (best effort, errors surface later during provisioning)
            if let team = try? await AuthManager.shared.getAuthenticatedTeam() {
                _ = try? await DeviceRegistrationFlow(handler: nil).registerCurrentDevice(for: team)
            }

            await self.snapshotActiveAccount()
            debugLog("[MultiAccountManager] Active account switched to \(target.appleID).")
        } catch {
            debugLog("[MultiAccountManager] Switching to \(target.appleID) failed: \(error). Rolling back...")
            if let previous, let previousCredentials {
                try? await self.applyLocally(previous, credentials: previousCredentials)
            }
            throw error
        }
    }

    private func applyLocally(_ account: PoolAccount, credentials: PoolCredentials) async throws {
        guard let accountIdentifier = account.accountIdentifier, let teamIdentifier = account.teamIdentifier else {
            throw MultiAccountError.accountNotInDatabase(account.appleID)
        }

        let auth = AuthManager.shared
        auth.currentAppleID = account.appleID
        auth.password = credentials.password
        auth.adsid = credentials.adsid
        auth.xcodeToken = credentials.xcodeToken

        Keychain.shared.signingCertificate = credentials.signingCertificateP12
        Keychain.shared.signingCertificatePassword = credentials.signingCertificatePassword
        _ = try? CertificateManager.shared.loadActiveCertificate()

        auth.resetCachedState()
        try await self.setActiveInDatabase(accountIdentifier: accountIdentifier, teamIdentifier: teamIdentifier)
    }

    private func setActiveInDatabase(accountIdentifier: String, teamIdentifier: String) async throws {
        guard DatabaseManager.shared.isStarted else { throw MultiAccountError.databaseUnavailable }

        try await DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
            let accounts = try context.fetch(Account.fetchRequest() as NSFetchRequest<Account>)
            let teams = try context.fetch(Team.fetchRequest() as NSFetchRequest<Team>)

            guard accounts.contains(where: { $0.identifier == accountIdentifier }),
                  let targetTeam = teams.first(where: { $0.identifier == teamIdentifier }) else
            {
                throw MultiAccountError.accountNotInDatabase(accountIdentifier)
            }

            for account in accounts { account.isActiveAccount = (account.identifier == accountIdentifier) }
            for team in teams { team.isActiveTeam = (team.identifier == teamIdentifier) }

            // keep the free-account active apps limit in sync, exactly like SignInOperation does
            let isSparseRestorePatched = ProcessInfo().sparseRestorePatched
            let isAppLimitDisabled = UserDefaults.standard.isAppLimitDisabled
            UserDefaults.standard.activeAppsLimit = nil
            if targetTeam.type == .free {
                if !isAppLimitDisabled && isSparseRestorePatched ||
                    isAppLimitDisabled && !isSparseRestorePatched
                {
                    UserDefaults.standard.activeAppsLimit = InstalledApp.freeAccountActiveAppsLimit
                }
            }

            try context.save()
        }

        await DatabaseManager.shared.viewContext.perform {
            DatabaseManager.shared.viewContext.processPendingChanges()
            DatabaseManager.shared.viewContext.refreshAllObjects()
        }
    }

    private func activeSessionIsValid() async -> Bool {
        do {
            let team = try await AuthManager.shared.getAuthenticatedTeam()
            _ = try await DeveloperPortalProxy.shared.fetchCertificates(team: team)
            return true
        } catch {
            debugLog("[MultiAccountManager] Session probe failed: \(error)")
            return false
        }
    }

    private func silentSignIn(_ account: PoolAccount, credentials: PoolCredentials) async throws {
        guard let password = credentials.password, !password.isEmpty else {
            throw MultiAccountError.missingCredentials(account.appleID)
        }
        let handler = SilentPoolSignInHandler(appleID: account.appleID,
                                              password: password,
                                              preferredTeamIdentifier: account.teamIdentifier)
        try await AuthManager.shared.signIn(handler: handler)
    }

    // MARK: App ID quota handling (called from the provisioning step)

    /// Heuristic detection of Apple's "too many App IDs" rejection (the SideSign error codes are not stable).
    static func isAppIDQuotaError(_ error: Error) -> Bool {
        let nsError = error as NSError
        var parts: [String] = [error.localizedDescription]
        if let reason = nsError.localizedFailureReason { parts.append(reason) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError { parts.append(underlying.localizedDescription) }
        let haystack = parts.joined(separator: " ").lowercased()

        let mentionsAppID = haystack.contains("app id") || haystack.contains("appid") || haystack.contains("identifier")
        let mentionsLimit = ["maximum", "limit", "exceed", "too many", "reached", "more than"].contains { haystack.contains($0) }
        return mentionsAppID && mentionsLimit
    }

    /// Rotates to a backup account after `exhaustedTeamIdentifier` ran out of App IDs.
    ///
    /// - Returns: the identifier of the team that is active afterwards, or `nil` when no switch happened
    ///   (no usable backup account, user declined, or every candidate failed).
    func handleAppIDQuotaExceeded(exhaustedTeamIdentifier: String, requiredAppIDs: Int) async throws -> String? {
        try await TaskChainCoalescer.shared.coalesce(key: "multi_account_rotate") { [self] in
            try await self.rotate(exhaustedTeamIdentifier: exhaustedTeamIdentifier, requiredAppIDs: requiredAppIDs)
        }
    }

    private func rotate(exhaustedTeamIdentifier: String, requiredAppIDs: Int) async throws -> String? {
        // another pipeline may already have switched accounts while we were waiting
        if let current = try? await AuthManager.shared.getAuthenticatedTeam(),
           current.identifier != exhaustedTeamIdentifier
        {
            return current.identifier
        }

        await self.snapshotActiveAccount()
        self.markExhausted(teamIdentifier: exhaustedTeamIdentifier)
        await self.refreshQuotaFromDatabase()
        self.markExhausted(teamIdentifier: exhaustedTeamIdentifier)

        let now = Date()
        let candidates = self.accounts
            .filter { $0.teamIdentifier != exhaustedTeamIdentifier }
            .filter { $0.remainingAppIDs(now: now) >= requiredAppIDs }
            .sorted { $0.remainingAppIDs(now: now) > $1.remainingAppIDs(now: now) }

        guard !candidates.isEmpty else {
            debugLog("[MultiAccountManager] No backup account has \(requiredAppIDs) free App ID slot(s).")
            return nil
        }

        for candidate in candidates {
            if !self.isAutoRotateEnabled {
                let approved = await self.promptToSwitch(to: candidate)
                guard approved else { return nil }
            }

            do {
                try await self.switchActiveAccount(to: candidate.appleID)
                return try await AuthManager.shared.getAuthenticatedTeam().identifier
            } catch {
                debugLog("[MultiAccountManager] Candidate \(candidate.appleID) could not be activated: \(error)")
                continue
            }
        }
        return nil
    }

    @MainActor
    private func promptToSwitch(to candidate: PoolAccount) async -> Bool {
        guard let presenter = Self.topViewController() else { return false }

        return await withCheckedContinuation { continuation in
            let remaining = candidate.remainingAppIDs()
            let slots = remaining == Int.max ? "∞" : String(remaining)
            let message = String(format: NSLocalizedString("The current Apple ID cannot register more App IDs this week. Switch to %@ (%@ free App IDs) and continue?", comment: ""),
                                 candidate.appleID, slots)
            let alert = UIAlertController(title: NSLocalizedString("App ID Limit Reached", comment: ""),
                                          message: message,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("Switch Account", comment: ""), style: .default) { _ in
                continuation.resume(returning: true)
            })
            alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            presenter.present(alert, animated: true)
        }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        var top = windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

// MARK: - Silent sign-in handler

/// Sign-in handler that never shows UI: it feeds the stored credentials once and refuses anything interactive.
private final class SilentPoolSignInHandler: SignInHandler, AnisetteServerHandler, @unchecked Sendable {
    private let appleID: String
    private let password: String
    private let preferredTeamIdentifier: String?

    private let lock = NSLock()
    private var didServeCredentials = false
    private var lastFailure: Error?

    init(appleID: String, password: String, preferredTeamIdentifier: String?) {
        self.appleID = appleID
        self.password = password
        self.preferredTeamIdentifier = preferredTeamIdentifier
    }

    func credentials() async throws -> (String, String) {
        // SignInOperation asks for credentials again after every rejected attempt. Without a user there is nobody
        // to retype them, so only serve them once and surface the original failure afterwards.
        let failure: Error? = lock.withLock {
            if didServeCredentials { return lastFailure ?? OperationError.cancelled }
            didServeCredentials = true
            return nil
        }
        if let failure { throw failure }
        return (appleID, password)
    }

    func verificationCode(for request: TwoFactorRequest) async throws -> TwoFactorResponse {
        // a verification code needs the user, so let the sign-in fail instead
        .cancel
    }

    func accountRepair(url: URL, message: String) async -> AccountRepairDecision { .cancel }

    func handleSignInResult(_ result: Result<(ALTAccount, ALTAppleAPISession), Error>) async {
        if case .failure(let error) = result {
            lock.withLock { lastFailure = error }
        }
    }

    func resolveTeam(_ teams: [ALTTeam]) async throws -> ALTTeam {
        if let preferredTeamIdentifier, let team = teams.first(where: { $0.identifier == preferredTeamIdentifier }) {
            return team
        }
        guard let first = teams.first else { throw DeveloperPortalError.noTeams }
        return first
    }

    func resolveProvisioningError(_ error: Error) async -> ProvisioningErrorDecision { .cancel }
    func resolveDeviceRegistrationErrors(_ error: Error) async -> ProvisioningErrorDecision { .skip }
    func resolvePostAuth() async {}

    func resolveRevocation(certificates: [ALTX509Certificate], teamType: ALTTeamType) async throws -> RevokeDecision {
        // never revoke certificates behind the user's back
        .keepExisting
    }

    func showCertificateSkipAcknowledgment() async {}
    func showDeviceRegistrationSkipAcknowledgment() async {}
    func resolveResign(mismatchReason: CodeSignValidationReason, context: StandaloneOperationContext) async throws -> Bool { false }
    func complete() async {}

    func warnOutdatedAnisetteServer() async throws -> Bool { true }
}
