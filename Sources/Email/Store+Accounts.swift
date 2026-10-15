import AppKit
import Contacts
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
                await loadAccountPhotos()
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
                await loadAccountPhotos()
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

    /// Your profile photo for each Google and Microsoft account. Google needs the "profile" permission, which accounts
    /// signed in before it was added don't have yet: those keep their initial until the next sign-in.
    func loadAccountPhotos() async {
        if AppFlavor.isDemo { return }
        // iCloud has no photo API: use the Mac's own "Me" card in Contacts, which usually carries the Apple Account photo.
        if state.accounts.contains(where: isICloud), let data = await meCardPhoto() {
            for a in state.accounts where isICloud(a) { SenderLogos.shared.setPhoto(a, data) }
        }
        for a in state.accounts where !isICloud(a) {
            do {
                var req: URLRequest
                if isMicrosoft(a) {
                    req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/photos/240x240/$value")!)
                    req.setValue("Bearer \(try await microsoft.accessToken(for: a))", forHTTPHeaderField: "Authorization")
                } else {
                    var info = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
                    info.setValue("Bearer \(try await auth.accessToken(for: a))", forHTTPHeaderField: "Authorization")
                    let (d, r) = try await URLSession.shared.data(for: info)
                    guard (r as? HTTPURLResponse)?.statusCode == 200, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          var pic = j["picture"] as? String else { continue }
                    if let eq = pic.lastIndex(of: "="), pic[eq...].hasPrefix("=s") { pic = String(pic[..<eq]) + "=s256-c" } // bigger than the default 96px
                    guard let u = URL(string: pic) else { continue }
                    req = URLRequest(url: u)
                }
                let (data, resp) = try await URLSession.shared.data(for: req)
                if (resp as? HTTPURLResponse)?.statusCode == 200 { SenderLogos.shared.setPhoto(a, data) }
            } catch { continue } // no photo or no permission: keep the initial
        }
    }

    /// Your "Me" card photo. Asks for Contacts access once; reads only that one card.
    func meCardPhoto() async -> Data? {
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            guard (try? await store.requestAccess(for: .contacts)) == true else { return nil }
        }
        let me = try? store.unifiedMeContactWithKeys(toFetch: [CNContactImageDataKey as CNKeyDescriptor, CNContactThumbnailImageDataKey as CNKeyDescriptor])
        return me?.imageData ?? me?.thumbnailImageData
    }

    /// Signs an existing Google or Microsoft account in again (new permissions, expired sign-in) without removing it.
    func reauthenticate(_ a: String) {
        if AppFlavor.isDemo { banner = "Signed in again."; return }
        Task {
            busy = "Finish signing in to \(a) in your browser…"
            defer { busy = nil }
            do {
                let email: String
                if isMicrosoft(a) { email = try await microsoft.signIn(hint: a) }
                else { email = try await auth.signIn(hint: a).email; await checkSettingsAccess(a) }
                guard email.lowercased() == a.lowercased() else {
                    banner = "You signed in as \(email), not \(a). Try again and pick \(a)."; return
                }
                banner = "Signed in again as \(a)."
                await loadAccountPhotos()
                await tick()
            } catch { report(error) }
        }
    }
}
