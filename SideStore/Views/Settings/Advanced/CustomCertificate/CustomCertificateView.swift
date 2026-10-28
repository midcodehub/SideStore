//
//  CustomCertificateView.swift
//  SideStore
//
//  Settings screen for "Custom Certificate / P12" signing mode (see `CustomCertificateSigner`).
//

import SwiftUI
import UniformTypeIdentifiers

private extension Color {
    static let customCertRowBackground = Color.white.opacity(0.15)
}

@MainActor
final class CustomCertificateViewModel: ObservableObject {
    enum ImportKind {
        case certificate
        case provisioningProfile
    }

    @Published private(set) var status: CustomCertificateSigner.Status = .notConfigured
    @Published var password: String = ""
    @Published var showFileImporter = false
    @Published private(set) var importKind: ImportKind = .certificate
    @Published var message: String?
    @Published private(set) var isEnabled: Bool = UserDefaults.standard.preferCustomCertificateSigning

    private let signer = CustomCertificateSigner.shared

    var allowedContentTypes: [UTType] {
        switch importKind {
        case .certificate:
            return [UTType(filenameExtension: "p12"), UTType(filenameExtension: "pfx")].compactMap { $0 }
        case .provisioningProfile:
            return [UTType(filenameExtension: "mobileprovision")].compactMap { $0 } + [.data]
        }
    }

    func refresh() {
        status = signer.status
        isEnabled = UserDefaults.standard.preferCustomCertificateSigning
    }

    func promptImport(_ kind: ImportKind) {
        if kind == .certificate, password.isEmpty {
            message = NSLocalizedString("Enter the .p12 password first.", comment: "")
            return
        }
        importKind = kind
        showFileImporter = true
    }

    func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            message = error.localizedDescription
        case .success(let url):
            do {
                switch importKind {
                case .certificate:
                    let certificate = try signer.importCertificate(from: url, password: password)
                    message = String(format: NSLocalizedString("Imported certificate %@.", comment: ""), certificate.name)
                    password = ""
                case .provisioningProfile:
                    let profile = try signer.importProvisioningProfile(from: url)
                    message = String(format: NSLocalizedString("Imported profile %@.", comment: ""), profile.name)
                }
            } catch {
                message = error.localizedDescription
            }
        }
        refresh()
        if isEnabled && !status.isReady {
            setEnabled(false)
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled && !status.isReady {
            message = NSLocalizedString("Import a matching certificate and provisioning profile before enabling custom signing.", comment: "")
            isEnabled = false
            return
        }
        UserDefaults.standard.preferCustomCertificateSigning = enabled
        isEnabled = enabled
    }

    func clear() {
        signer.clear()
        password = ""
        message = NSLocalizedString("Custom certificate material removed.", comment: "")
        refresh()
    }

    var statusDescription: (text: String, isOK: Bool) {
        switch status {
        case .notConfigured:
            return (NSLocalizedString("No certificate or profile imported.", comment: ""), false)
        case .missingCertificate:
            return (NSLocalizedString("The .p12 certificate is missing.", comment: ""), false)
        case .missingProfile:
            return (NSLocalizedString("The .mobileprovision profile is missing.", comment: ""), false)
        case .mismatch:
            return (NSLocalizedString("The certificate is not included in the provisioning profile.", comment: ""), false)
        case .expired(let date):
            return (String(format: NSLocalizedString("The provisioning profile expired on %@.", comment: ""),
                           DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)), false)
        case .ready(let summary):
            return (String(format: NSLocalizedString("Ready: %@ · team %@ · valid until %@", comment: ""),
                           summary.certificateName,
                           summary.teamIdentifier,
                           DateFormatter.localizedString(from: summary.profileExpiration, dateStyle: .medium, timeStyle: .none)), true)
        }
    }
}

struct CustomCertificateView: View {
    @StateObject private var viewModel = CustomCertificateViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                statusSection
                importSection
                modeSection

                if let message = viewModel.message {
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
        .navigationTitle(NSLocalizedString("Custom Certificate / P12", comment: ""))
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { viewModel.refresh() }
        #if !os(tvOS)
        .fileImporter(isPresented: $viewModel.showFileImporter,
                      allowedContentTypes: viewModel.allowedContentTypes) { result in
            viewModel.handleImport(result)
        }
        #endif
    }

    private var statusSection: some View {
        let description = viewModel.statusDescription
        return card(title: NSLocalizedString("STATUS", comment: "")) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: description.isOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(description.isOK ? .green : .orange)
                Text(description.text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }

    private var importSection: some View {
        card(title: NSLocalizedString("IMPORT", comment: "")) {
            VStack(spacing: 0) {
                SecureField(NSLocalizedString("Certificate password", comment: ""), text: $viewModel.password)
                    .textContentType(.password)
                    .padding(14)
                Divider().background(Color.white.opacity(0.15))
                actionRow(title: NSLocalizedString("Choose .p12 Certificate…", comment: ""), systemImage: "key") {
                    viewModel.promptImport(.certificate)
                }
                Divider().background(Color.white.opacity(0.15))
                actionRow(title: NSLocalizedString("Choose .mobileprovision Profile…", comment: ""), systemImage: "doc.badge.gearshape") {
                    viewModel.promptImport(.provisioningProfile)
                }
                Divider().background(Color.white.opacity(0.15))
                actionRow(title: NSLocalizedString("Remove Imported Material", comment: ""), systemImage: "trash") {
                    viewModel.clear()
                }
            }
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            card(title: NSLocalizedString("MODE", comment: "")) {
                Toggle(isOn: Binding(get: { viewModel.isEnabled }, set: { viewModel.setEnabled($0) })) {
                    Text(NSLocalizedString("Prefer Custom Certificate Signing", comment: ""))
                }
                .padding(14)
            }
            Text(NSLocalizedString("When enabled, installing and re-signing apps skips the Apple ID, App ID and certificate requests and signs with the imported .p12 and .mobileprovision. SideStore itself keeps using your Apple ID. Apps signed this way cannot be refreshed through the Developer Portal.", comment: ""))
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                content()
            }
            .background(Color.customCertRowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func actionRow(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        SwiftUI.Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).frame(width: 24)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

