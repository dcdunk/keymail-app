import AppKit
import SwiftUI
import EmailCore
import CryptoKit

extension AppStore {
    // MARK: Accounts

    func addAccount() {
        if AppFlavor.isDemo { addDemoAccount("gmail"); return }
        Task {
            busy = "Waiting for Google sign-in in your browser…"
            do {
                let email = try await auth.signIn().email
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
        if AppFlavor.isDemo { addDemoAccount("icloud"); return } // the sheet still shows; anything typed is ignored
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

    // MARK: Microsoft (Outlook.com, Hotmail, Microsoft 365)

    func connectMicrosoft() {
        if AppFlavor.isDemo { addDemoAccount("microsoft"); return }
        Task {
            busy = "Waiting for Microsoft sign-in in your browser…"
            defer { busy = nil }
            do {
                let email = try await microsoft.signIn()
                if !state.accounts.contains(email) { state.accounts.append(email) }
                if !state.microsoft.contains(email) { state.microsoft.append(email) }
                busy = "Loading \(email)…"
                try await syncMicrosoft(email)
                saveCache()
                banner = "Added \(email)."
            } catch { report(error) }
        }
    }

    func removeAccount(_ a: String) {
        Keychain.delete(a)
        Keychain.delete(MicrosoftAuth.keychainKey(a)); microsoft.invalidate(a); state.microsoft.removeAll { $0 == a }
        Keychain.delete(ICloud.keychainKey(a))
        state.forget(a)
        messages = messages.filter { $0.value.account != a }
        saveCache()
    }
}
