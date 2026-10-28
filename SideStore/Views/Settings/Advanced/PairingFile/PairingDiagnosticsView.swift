//
//  PairingDiagnosticsView.swift
//  SideStore
//
//  "Pairing & Tunnel Diagnostics" panel. Presents the report from `PairingRecoveryService`.
//

import SwiftUI
import UniformTypeIdentifiers

private extension Color {
    static let diagnosticsRowBackground = Color.white.opacity(0.15)
}

@MainActor
final class PairingDiagnosticsViewModel: ObservableObject {
    @Published private(set) var report: PairingRecoveryService.HealthReport?
    @Published private(set) var isChecking = false
    @Published var showFileImporter = false
    @Published var statusMessage: String?

    private let service = PairingRecoveryService.shared

    func runCheck() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        report = await service.checkTunnelAndPairingHealth()
    }

    func handleImport(_ result: Result<URL, Error>) async {
        switch result {
        case .success(let url):
            do {
                try PairingFileManager.shared.importPairingFile(from: url)
                if let contents = PairingFileManager.shared.fetchPairingFile() {
                    try await AppBootManager.shared.startMinimuxer(pairingFile: contents)
                }
                statusMessage = NSLocalizedString("Pairing file imported and backed up to Keychain.", comment: "")
            } catch {
                statusMessage = String(format: NSLocalizedString("Failed to import pairing file: %@", comment: ""), error.localizedDescription)
            }
            await runCheck()
        case .failure(let error):
            statusMessage = error.localizedDescription
        }
    }

    func openLocalDevVPN() async {
        let opened = await service.openLocalDevVPN()
        if !opened {
            statusMessage = NSLocalizedString("LocalDevVPN could not be opened. Make sure it is installed.", comment: "")
        }
    }

    func openDeveloperModeSettings() async {
        await service.openDeveloperModeSettings()
    }

    // MARK: Presentation helpers

    var tunnelDescription: (text: String, isOK: Bool) {
        guard let report else { return (NSLocalizedString("Checking…", comment: ""), false) }
        switch report.tunnel {
        case .connected(let interface, let address):
            return (String(format: NSLocalizedString("Connected (%@ · %@)", comment: ""), interface, address), true)
        case .reachable(let peer):
            return (String(format: NSLocalizedString("Reachable (peer %@)", comment: ""), peer), true)
        case .disconnected:
            return (NSLocalizedString("Not connected. Enable LocalDevVPN.", comment: ""), false)
        }
    }

    var pairingDescription: (text: String, isOK: Bool) {
        guard let report else { return (NSLocalizedString("Checking…", comment: ""), false) }
        switch report.pairing {
        case .valid(let protocolName):
            return (String(format: NSLocalizedString("Valid session (%@)", comment: ""), protocolName), true)
        case .missing:
            return (NSLocalizedString("No pairing file found.", comment: ""), false)
        case .invalid(let reason):
            return (String(format: NSLocalizedString("Invalid: %@", comment: ""), reason), false)
        case .notLoaded:
            return (NSLocalizedString("Pairing file present but not loaded by minimuxer.", comment: ""), false)
        case .unverified(let reason):
            return (String(format: NSLocalizedString("Unverified: %@", comment: ""), reason), false)
        }
    }

    var backupDescription: (text: String, isOK: Bool) {
        guard let report else { return (NSLocalizedString("Checking…", comment: ""), false) }
        switch (report.hasSandboxFile, report.hasKeychainBackup) {
        case (_, true):
            return (NSLocalizedString("Encrypted Keychain backup present.", comment: ""), true)
        case (true, false):
            return (NSLocalizedString("No Keychain backup yet. It is created on the next launch or import.", comment: ""), false)
        case (false, false):
            return (NSLocalizedString("No backup available.", comment: ""), false)
        }
    }
}

struct PairingDiagnosticsView: View {
    @StateObject private var viewModel = PairingDiagnosticsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                statusSection
                actionsSection

                if let message = viewModel.statusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .settingsBackground).ignoresSafeArea())
        .navigationTitle(NSLocalizedString("Pairing & Tunnel Diagnostics", comment: ""))
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await viewModel.runCheck()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await viewModel.runCheck() }
        }
        #if !os(tvOS)
        .fileImporter(isPresented: $viewModel.showFileImporter,
                      allowedContentTypes: PairingFileManager.supportedContentTypes) { result in
            Task { await viewModel.handleImport(result) }
        }
        #endif
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("STATUS", comment: ""))
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                statusRow(title: NSLocalizedString("VPN Tunnel", comment: ""), value: viewModel.tunnelDescription)
                Divider().background(Color.white.opacity(0.15))
                statusRow(title: NSLocalizedString("Pairing File", comment: ""), value: viewModel.pairingDescription)
                Divider().background(Color.white.opacity(0.15))
                statusRow(title: NSLocalizedString("Keychain Backup", comment: ""), value: viewModel.backupDescription)
            }
            .background(Color.diagnosticsRowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func statusRow(title: String, value: (text: String, isOK: Bool)) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: value.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(value.isOK ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(value.text)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("ACTIONS", comment: ""))
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                actionRow(title: NSLocalizedString("Run Diagnostics Again", comment: ""), systemImage: "arrow.clockwise") {
                    Task { await viewModel.runCheck() }
                }
                Divider().background(Color.white.opacity(0.15))
                actionRow(title: NSLocalizedString("Open LocalDevVPN", comment: ""), systemImage: "lock.shield") {
                    Task { await viewModel.openLocalDevVPN() }
                }
                Divider().background(Color.white.opacity(0.15))
                actionRow(title: NSLocalizedString("Re-import Pairing File", comment: ""), systemImage: "square.and.arrow.down") {
                    viewModel.showFileImporter = true
                }
                Divider().background(Color.white.opacity(0.15))
                actionRow(title: NSLocalizedString("Open Developer Mode Settings", comment: ""), systemImage: "hammer") {
                    Task { await viewModel.openDeveloperModeSettings() }
                }
            }
            .background(Color.diagnosticsRowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(NSLocalizedString("Developer Mode lives under Settings → Privacy & Security → Developer Mode. If the shortcut does not open it, navigate there manually.", comment: ""))
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func actionRow(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        SwiftUI.Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                Text(title)
                Spacer()
                if viewModel.isChecking && systemImage == "arrow.clockwise" {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

