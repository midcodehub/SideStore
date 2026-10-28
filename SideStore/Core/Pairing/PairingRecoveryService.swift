//
//  PairingRecoveryService.swift
//  SideStore
//
//  Keychain mirror of the pairing file(s) plus a tunnel / pairing self-diagnosis.
//
//  Needs proper testing on a physical device (Keychain survival across overwrite-updates, iOS 27 pairing session behavior).
//

import Foundation
import UIKit
import CryptoKit
import Minimuxer
import MinimuxerCommon

final class PairingRecoveryService: @unchecked Sendable {
    static let shared = PairingRecoveryService()

    // MARK: - Diagnostics models

    enum TunnelStatus: Sendable, Equatable {
        /// A `utun` interface with a 10.7.x.x address (LocalDevVPN) is up.
        case connected(interface: String, address: String)
        /// No matching `utun` interface was found, but the configured tunnel peer answered a probe.
        case reachable(peer: String)
        case disconnected
    }

    enum PairingStatus: Sendable, Equatable {
        /// No pairing file exists in the sandbox.
        case missing
        /// The pairing file in the sandbox could not be parsed.
        case invalid(reason: String)
        /// The file exists and parses, but minimuxer has not loaded it (not started, or start failed).
        case notLoaded
        /// The pairing file could not be verified right now (e.g. the tunnel is down).
        case unverified(reason: String)
        /// A live lockdown / remote pairing session succeeded with this pairing file.
        case valid(protocolName: String)
    }

    struct HealthReport: Sendable {
        let tunnel: TunnelStatus
        let pairing: PairingStatus
        let hasSandboxFile: Bool
        let hasKeychainBackup: Bool
        let checkedAt: Date

        var isHealthy: Bool {
            if case .valid = pairing, tunnel != .disconnected { return true }
            return false
        }
    }

    // MARK: - Keychain backup

    private struct TrackedFile {
        let fileName: String
    }

    private let trackedFiles: [TrackedFile] = [
        TrackedFile(fileName: AppConstants.Pairing.lockdownPairingFileName),
        TrackedFile(fileName: AppConstants.Pairing.remotePairingFileName)
    ]

    private let backupKeyPrefix = "pairingBackup."
    private let sealingKeyName = "pairingBackupSealingKey"

    private init() {}

    func fileName(for mode: PairingProtocol) -> String {
        mode == .rppairing ? AppConstants.Pairing.remotePairingFileName : AppConstants.Pairing.lockdownPairingFileName
    }

    private func sealingKey() -> SymmetricKey {
        if let data = Keychain.shared[localKey: sealingKeyName], data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        Keychain.shared[localKey: sealingKeyName] = keyData
        return key
    }

    /// Encrypts (AES-256-GCM) and stores the pairing file contents in the device-local Keychain.
    func backup(contents: String, fileName: String) {
        guard let plain = contents.data(using: .utf8), !plain.isEmpty else { return }
        do {
            let sealed = try AES.GCM.seal(plain, using: self.sealingKey())
            guard let combined = sealed.combined else { return }
            Keychain.shared[localKey: self.backupKeyPrefix + fileName] = combined
            debugLog("[PairingRecovery] Backed up '\(fileName)' to Keychain (\(combined.count) bytes).")
        } catch {
            debugLog("[PairingRecovery] Failed to back up '\(fileName)': \(error)")
        }
    }

    func loadBackup(fileName: String) -> String? {
        guard let combined = Keychain.shared[localKey: self.backupKeyPrefix + fileName] else { return nil }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plain = try AES.GCM.open(box, using: self.sealingKey())
            return String(data: plain, encoding: .utf8)
        } catch {
            debugLog("[PairingRecovery] Failed to decrypt Keychain backup for '\(fileName)': \(error)")
            return nil
        }
    }

    func hasBackup(fileName: String) -> Bool {
        Keychain.shared[localKey: self.backupKeyPrefix + fileName] != nil
    }

    var hasAnyBackup: Bool {
        self.trackedFiles.contains { self.hasBackup(fileName: $0.fileName) }
    }

    func removeBackup(fileName: String) {
        Keychain.shared[localKey: self.backupKeyPrefix + fileName] = nil
    }

    func removeAllBackups() {
        for file in self.trackedFiles {
            self.removeBackup(fileName: file.fileName)
        }
    }

    // MARK: - Boot-time reconciliation

    /// Restores pairing files that disappeared from the sandbox (overwrite update / cache cleanup) from the Keychain
    /// and backs up sandbox files that have no Keychain mirror yet (existing installs).
    ///
    /// - Returns: `true` if at least one file was restored into the sandbox.
    @discardableResult
    func reconcileOnLaunch() -> Bool {
        let fm = FileManager.default
        var restored = false

        for file in self.trackedFiles {
            let url = fm.documentsDirectory.appendingPathComponent(file.fileName)

            if fm.fileExists(atPath: url.path) {
                guard !self.hasBackup(fileName: file.fileName),
                      let contents = try? String(contentsOf: url), !contents.isEmpty else { continue }
                self.backup(contents: contents, fileName: file.fileName)
                continue
            }

            guard let contents = self.loadBackup(fileName: file.fileName) else { continue }
            do {
                let mode: PairingProtocol = file.fileName == AppConstants.Pairing.remotePairingFileName ? .rppairing : .lockdown
                let parsed = try PairingFileManager.shared.savePairingFile(contents: contents, preferred: mode)
                if PairingFileManager.shared.persistedActiveProtocol == nil {
                    PairingFileManager.shared.persistedActiveProtocol = parsed.mode
                }
                restored = true
                debugLog("[PairingRecovery] Restored '\(file.fileName)' from Keychain backup.")
            } catch {
                debugLog("[PairingRecovery] Keychain backup for '\(file.fileName)' is not a valid pairing file: \(error)")
                self.removeBackup(fileName: file.fileName)
            }
        }
        return restored
    }

    // MARK: - Diagnostics

    /// Probes the loopback tunnel (LocalDevVPN / `10.7.0.1`) and validates the current pairing session.
    func checkTunnelAndPairingHealth() async -> HealthReport {
        let tunnel = self.probeTunnel()
        let pairing = await self.verifyPairing(tunnel: tunnel)

        let fm = FileManager.default
        let hasSandboxFile = self.trackedFiles.contains {
            fm.fileExists(atPath: fm.documentsDirectory.appendingPathComponent($0.fileName).path)
        }

        return HealthReport(tunnel: tunnel,
                            pairing: pairing,
                            hasSandboxFile: hasSandboxFile,
                            hasKeychainBackup: self.hasAnyBackup,
                            checkedAt: Date())
    }

    /// Synchronous tunnel probe: first looks for a `utun` interface in the LocalDevVPN range, then pings the tunnel peer.
    func probeTunnel() -> TunnelStatus {
        #if targetEnvironment(simulator)
        return .disconnected
        #else
        let interfaces = minimuxer.network.activeInterfaces
        if let tunnel = interfaces.first(where: { $0.name.lowercased().hasPrefix("utun") && $0.ip.hasPrefix("10.7.") }) {
            return .connected(interface: tunnel.name, address: tunnel.ip)
        }

        let peer = ConnectionConfig.shared.tunnelPeerIp ?? AppConstants.Connection.defaultOverrideIP
        if !peer.isEmpty, minimuxer.core.testDeviceConnection(ifaddr: peer, timeout: 200) {
            return .reachable(peer: peer)
        }
        return .disconnected
        #endif
    }

    private func verifyPairing(tunnel: TunnelStatus) async -> PairingStatus {
        let manager = PairingFileManager.shared
        guard let contents = manager.fetchPairingFile() else {
            return .missing
        }

        let parsed: any PairingFile
        do {
            parsed = try manager.parse(content: contents)
        } catch {
            return .invalid(reason: error.localizedDescription)
        }

        #if targetEnvironment(simulator)
        return .unverified(reason: "Pairing sessions cannot be verified on the simulator.")
        #else
        guard minimuxer.core.isPairingFileLoaded else {
            return .notLoaded
        }
        guard tunnel != .disconnected else {
            return .unverified(reason: NSLocalizedString("The local tunnel is not connected.", comment: ""))
        }

        do {
            // A live UDID round-trip proves that the lockdown / remote-pairing session is accepted by the OS.
            _ = try await fetchUDID(forceLive: true)
            return .valid(protocolName: String(describing: parsed.mode))
        } catch {
            if case MinimuxerError.invalidPairing = error {
                return .invalid(reason: error.localizedDescription)
            }
            return .unverified(reason: error.localizedDescription)
        }
        #endif
    }

    // MARK: - Quick actions

    /// Tries to wake LocalDevVPN through its URL scheme. Returns `false` if the app could not be opened.
    @MainActor
    func openLocalDevVPN() async -> Bool {
        guard let url = URL(string: "localdevvpn://enable?scheme=sidestore") else { return false }
        return await UIApplication.shared.open(url, options: [:])
    }

    /// Opens Settings -> Privacy & Security -> Developer Mode when possible, falling back to the app's own Settings page.
    ///
    /// The deep link is a private Settings URL and might stop working on newer iOS versions (needs proper testing on iOS 27).
    @MainActor
    func openDeveloperModeSettings() async {
        if let deepLink = URL(string: "App-prefs:Privacy&path=DEVELOPER_MODE"),
           await UIApplication.shared.open(deepLink, options: [:]) {
            return
        }
        if let fallback = URL(string: UIApplication.openSettingsURLString) {
            _ = await UIApplication.shared.open(fallback, options: [:])
        }
    }
}

