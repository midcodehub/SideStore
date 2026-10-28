//
//  CustomCertificateSigner.swift
//  SideStore
//
//  Offline signing with a user supplied `.p12` + `.mobileprovision`.
//
//  When active, the install / resign pipeline skips the Apple Developer Portal (certificate, App ID and profile
//  requests) and feeds the local material straight into the existing "override" hooks of `InstallAppOperationContext`
//  (`overrideSigningCertificate` / `overrideProvisioningProfile`). The signed app is then installed through the usual
//  Minimuxer + LocalDevVPN channel.
//
//  Needs proper testing with real certificates (wildcard profiles, extensions, expired material).
//

import Foundation
import SideSign

final class CustomCertificateSigner: @unchecked Sendable {
    static let shared = CustomCertificateSigner()

    static let didChangeNotification = Notification.Name("CustomCertificateSigner.didChange")

    // MARK: - Types

    enum ImportError: LocalizedError {
        case unreadableFile(String)
        case invalidPassword
        case invalidProvisioningProfile(String)
        case profileExpired(Date)

        var errorDescription: String? {
            switch self {
            case .unreadableFile(let reason):
                return String(format: NSLocalizedString("The selected file could not be read: %@", comment: ""), reason)
            case .invalidPassword:
                return NSLocalizedString("The certificate could not be opened. Check the .p12 password.", comment: "")
            case .invalidProvisioningProfile(let reason):
                return String(format: NSLocalizedString("The provisioning profile is invalid: %@", comment: ""), reason)
            case .profileExpired(let date):
                return String(format: NSLocalizedString("The provisioning profile expired on %@.", comment: ""),
                              DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none))
            }
        }
    }

    struct Summary: Sendable, Equatable {
        let certificateName: String
        let certificateSerial: String
        let profileName: String
        let profileBundleIdentifier: String
        let teamIdentifier: String
        let profileExpiration: Date
    }

    enum Status: Sendable, Equatable {
        case notConfigured
        case missingCertificate
        case missingProfile
        /// The imported certificate is not one of the certificates embedded in the profile.
        case mismatch
        case expired(Date)
        case ready(Summary)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    // MARK: - Storage

    private let p12Key = "customCertificate.p12"
    private let passwordKey = "customCertificate.password"
    private let profileKey = "customCertificate.profile"

    private let fileManager = FileManager.default

    private var storageDirectory: URL {
        let url = fileManager.applicationSupportDirectory.appendingPathComponent("CustomCertificate", isDirectory: true)
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
        return url
    }

    private var p12FileURL: URL { storageDirectory.appendingPathComponent("certificate.p12") }
    private var profileFileURL: URL { storageDirectory.appendingPathComponent("profile.mobileprovision") }

    private init() {}

    private func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func readSecurityScoped(_ url: URL) throws -> Data {
        let isSecured = url.startAccessingSecurityScopedResource()
        defer { if isSecured { url.stopAccessingSecurityScopedResource() } }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ImportError.unreadableFile(error.localizedDescription)
        }
    }

    // MARK: - Import

    /// Validates the password by opening the archive, then stores it in the sandbox and the Keychain.
    @discardableResult
    func importCertificate(from url: URL, password: String) throws -> ALTCertificate {
        let data = try readSecurityScoped(url)

        let certificate: ALTCertificate
        do {
            certificate = try ALTCertificate(p12Data: data, password: password)
        } catch {
            debugLog("[CustomCertificateSigner] Failed to open p12: \(error)")
            throw ImportError.invalidPassword
        }

        try writeProtected(data, to: p12FileURL)
        Keychain.shared[dynamicKey: p12Key] = data
        Keychain.shared[dynamicKey: passwordKey] = password.data(using: .utf8)

        debugLog("[CustomCertificateSigner] Imported certificate '\(certificate.name)' (serial \(certificate.serialNumber)).")
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        return certificate
    }

    @discardableResult
    func importProvisioningProfile(from url: URL) throws -> ALTProvisioningProfile {
        let data = try readSecurityScoped(url)

        let profile: ALTProvisioningProfile
        do {
            profile = try ALTProvisioningProfile(data: data)
        } catch {
            throw ImportError.invalidProvisioningProfile(error.localizedDescription)
        }
        guard profile.expirationDate > Date() else {
            throw ImportError.profileExpired(profile.expirationDate)
        }

        try writeProtected(data, to: profileFileURL)
        Keychain.shared[dynamicKey: profileKey] = data

        debugLog("[CustomCertificateSigner] Imported provisioning profile '\(profile.name)' (\(profile.uuid)).")
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        return profile
    }

    func clear() {
        Keychain.shared[dynamicKey: p12Key] = nil
        Keychain.shared[dynamicKey: passwordKey] = nil
        Keychain.shared[dynamicKey: profileKey] = nil
        try? fileManager.removeItem(at: p12FileURL)
        try? fileManager.removeItem(at: profileFileURL)
        UserDefaults.standard.preferCustomCertificateSigning = false
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: - Loading

    /// The Keychain is the source of truth, the sandbox copy restores it when the Keychain item was lost.
    private func storedP12() -> Data? {
        if let data = Keychain.shared[dynamicKey: p12Key] { return data }
        guard let data = try? Data(contentsOf: p12FileURL) else { return nil }
        Keychain.shared[dynamicKey: p12Key] = data
        return data
    }

    private func storedProfileData() -> Data? {
        if let data = Keychain.shared[dynamicKey: profileKey] { return data }
        guard let data = try? Data(contentsOf: profileFileURL) else { return nil }
        Keychain.shared[dynamicKey: profileKey] = data
        return data
    }

    private func loadCertificate() -> ALTCertificate? {
        guard let data = storedP12(),
              let passwordData = Keychain.shared[dynamicKey: passwordKey],
              let password = String(data: passwordData, encoding: .utf8) else { return nil }
        return try? ALTCertificate(p12Data: data, password: password)
    }

    private func loadProfile() -> ALTProvisioningProfile? {
        guard let data = storedProfileData() else { return nil }
        return try? ALTProvisioningProfile(data: data)
    }

    private func normalized(_ serial: String) -> String {
        var s = serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("0X") { s.removeFirst(2) }
        while s.hasPrefix("0") && s.count > 1 { s.removeFirst() }
        return s
    }

    var status: Status {
        let hasP12 = storedP12() != nil
        let hasProfile = storedProfileData() != nil
        guard hasP12 || hasProfile else { return .notConfigured }
        guard hasP12, let certificate = loadCertificate() else { return .missingCertificate }
        guard hasProfile, let profile = loadProfile() else { return .missingProfile }
        guard profile.expirationDate > Date() else { return .expired(profile.expirationDate) }

        let serial = normalized(certificate.serialNumber)
        let matches = profile.certificates.contains { profileCertificate in
            normalized(profileCertificate.serialNumber) == serial
                || (profileCertificate.data != nil && profileCertificate.data == certificate.data)
        }
        guard matches else { return .mismatch }

        return .ready(Summary(certificateName: certificate.name,
                              certificateSerial: certificate.serialNumber,
                              profileName: profile.name,
                              profileBundleIdentifier: profile.bundleIdentifier,
                              teamIdentifier: profile.teamIdentifier,
                              profileExpiration: profile.expirationDate))
    }

    /// `true` when the user opted in and the stored material is complete, matching and not expired.
    var isActive: Bool {
        UserDefaults.standard.preferCustomCertificateSigning && status.isReady
    }

    // MARK: - Pipeline integration

    /// A team description derived from the profile, used where the pipeline needs an `ALTTeam` but no Apple ID is involved.
    var signingTeam: ALTTeam? {
        guard let profile = loadProfile() else { return nil }
        return ALTTeam(identifier: profile.teamIdentifier, name: profile.teamName, type: .individual)
    }

    /// Redirects the pipeline context to the local material. Returns `false` if the material could not be loaded.
    @discardableResult
    func apply(to context: InstallAppOperationContext) -> Bool {
        guard let certificate = loadCertificate(), let profile = loadProfile() else {
            debugLog("[CustomCertificateSigner] Material could not be loaded. Falling back to the Apple ID flow.")
            return false
        }
        context.overrideSigningCertificate = certificate
        context.overrideProvisioningProfile = profile
        context.usesCustomCertificate = true
        return true
    }
}

