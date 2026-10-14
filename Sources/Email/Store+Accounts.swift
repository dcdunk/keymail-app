import AppKit
import SwiftUI
import EmailCore
import CryptoKit

extension AppStore {
    // MARK: Accounts

    func addAccount() {
        Task {
            busy = "Waiting for Google sign-in in your browser…"
            do {
                let email = try await auth.signIn()
                if !state.accounts.contains(email) { state.accounts.append(email) }
                state.historyIds[email] = nil
                busy = nil
                try await fullSync(email)
                saveCache()
            } catch { busy = nil; report(error) }
        }
    }

    /// Checks the app-specific password with iCloud before saving it to the Keychain.
    func addICloudAccount(email: String, password: String, aliases: String = "") async throws {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        let found = try await ICloud.findLogin(email: e, password: password)
        Keychain.set(found.password, for: ICloud.keychainKey(e))
        state.icloudLogins[e] = found.login
        setAliases(aliases, for: e)
        if !state.accounts.contains(e) { state.accounts.append(e) }
        if !state.icloud.contains(e) { state.icloud.append(e) }
        Task {
            busy = "Loading \(e)…"
            defer { busy = nil }
            do { try await syncICloud(e); saveCache() } catch { report(error) }
        }
    }

    func removeAccount(_ a: String) {
        Keychain.delete(a)
        Keychain.delete(ICloud.keychainKey(a))
        state.icloud.removeAll { $0 == a }
        state.aliases[a] = nil
        state.defaultFrom[a] = nil
        state.accountNames[a] = nil
        state.accounts.removeAll { $0 == a }
        if state.activeAccount == a { state.activeAccount = nil }
        state.historyIds[a] = nil
        messages = messages.filter { $0.value.account != a }
        saveCache()
    }
}
