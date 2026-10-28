//
//  AccountPoolView.swift
//  SideStore
//
//  Settings screen for the Apple ID account pool (see `MultiAccountManager`).
//

import SwiftUI

private extension Color {
    static let accountPoolRowBackground = Color.white.opacity(0.15)
}

@MainActor
final class AccountPoolViewModel: ObservableObject {
    @Published private(set) var accounts: [PoolAccount] = []
    @Published private(set) var activeAppleID: String?
    @Published private(set) var isBusy = false
    @Published var message: String?
    @Published private(set) var autoRotate: Bool = UserDefaults.standard.isAccountPoolAutoRotateEnabled

    private let manager = MultiAccountManager.shared

    func reload() async {
        await manager.snapshotActiveAccount()
        await manager.refreshQuotaFromDatabase()
        accounts = manager.accounts
        activeAppleID = manager.activeAppleID
    }

    func addAccount(presenting viewController: UIViewController?) async {
        guard let viewController else { return }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try await manager.addAccount(presenting: viewController)
            message = NSLocalizedString("Backup Apple ID added. The default signing account was not changed.", comment: "")
        } catch is CancellationError {
            // user cancelled
        } catch {
            message = error.localizedDescription
        }
        await reload()
    }

    func switchTo(_ account: PoolAccount) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try await manager.switchActiveAccount(to: account.appleID)
            message = String(format: NSLocalizedString("%@ is now the default signing account.", comment: ""), account.appleID)
        } catch {
            message = error.localizedDescription
        }
        await reload()
    }

    func remove(_ account: PoolAccount) async {
        do {
            try manager.removeAccount(appleID: account.appleID)
        } catch {
            message = error.localizedDescription
        }
        await reload()
    }

    func setAutoRotate(_ enabled: Bool) {
        UserDefaults.standard.isAccountPoolAutoRotateEnabled = enabled
        autoRotate = enabled
    }

    func quotaText(for account: PoolAccount) -> String {
        guard account.isFreeTeam else { return NSLocalizedString("Paid team · no weekly App ID limit", comment: "") }
        var text = String(format: NSLocalizedString("%d / %d App IDs used", comment: ""), account.appIDsUsed, Team.maximumFreeAppIDs)
        if let reset = account.quotaResetDate, account.appIDsUsed >= Team.maximumFreeAppIDs {
            text += " · " + String(format: NSLocalizedString("next slot frees %@", comment: ""),
                                   DateFormatter.localizedString(from: reset, dateStyle: .medium, timeStyle: .short))
        }
        return text
    }
}

struct AccountPoolView: View {
    @StateObject private var viewModel = AccountPoolViewModel()

    /// Needed to present the Apple ID sign-in UI when adding a backup account.
    weak var presentingViewController: UIViewController?

    init(presentingViewController: UIViewController?) {
        self.presentingViewController = presentingViewController
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                accountsSection
                optionsSection

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
        .navigationTitle(NSLocalizedString("Account Pool", comment: ""))
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await viewModel.reload() }
        .onReceive(NotificationCenter.default.publisher(for: MultiAccountManager.poolDidChangeNotification)) { _ in
            Task { await viewModel.reload() }
        }
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("APPLE IDS", comment: ""))
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                if viewModel.accounts.isEmpty {
                    Text(NSLocalizedString("Sign in with an Apple ID first. It becomes the primary account of the pool.", comment: ""))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(14)
                }

                ForEach(viewModel.accounts) { account in
                    accountRow(account)
                    Divider().background(Color.white.opacity(0.15))
                }

                SwiftUI.Button {
                    Task { await viewModel.addAccount(presenting: presentingViewController) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle").frame(width: 24)
                        Text(NSLocalizedString("Add Backup Apple ID…", comment: ""))
                        Spacer()
                        if viewModel.isBusy { ProgressView() }
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isBusy)
            }
            .background(Color.accountPoolRowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func accountRow(_ account: PoolAccount) -> some View {
        let isActive = account.appleID.lowercased() == viewModel.activeAppleID?.lowercased()
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: isActive ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                .foregroundColor(isActive ? .green : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.appleID)
                    .font(.headline)
                if let teamName = account.teamName {
                    Text(teamName)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Text(viewModel.quotaText(for: account))
                    .font(.footnote)
                    .foregroundColor(account.isExhausted() ? .orange : .secondary)
            }

            Spacer(minLength: 0)

            if isActive {
                Text(NSLocalizedString("Active", comment: ""))
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.green)
            } else {
                Menu {
                    SwiftUI.Button(NSLocalizedString("Use for Signing", comment: "")) {
                        Task { await viewModel.switchTo(account) }
                    }
                    SwiftUI.Button(NSLocalizedString("Remove", comment: ""), role: .destructive) {
                        Task { await viewModel.remove(account) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(viewModel.isBusy)
            }
        }
        .padding(14)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { viewModel.autoRotate }, set: { viewModel.setAutoRotate($0) })) {
                Text(NSLocalizedString("Switch Automatically", comment: ""))
            }
            .padding(14)
            .background(Color.accountPoolRowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(NSLocalizedString("When an Apple ID reaches Apple's limit of 10 new App IDs per week while installing an app, SideStore either asks before using the next Apple ID with free slots, or switches on its own when this is enabled. Apps stay tied to the account that signed them.", comment: ""))
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
        }
    }
}

