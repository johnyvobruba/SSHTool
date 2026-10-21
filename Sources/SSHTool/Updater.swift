import Foundation
import AppKit
import CryptoKit

/// Aktualizace z GitHub Releases (veřejné repo, bez tokenu).
/// 1) GET api.github.com/repos/<repo>/releases/latest → verze, poznámky, soubory
/// 2) dotaz uživateli (poznámky k vydání) → stažení SSHTool-x.y.z.zip + .sig
/// 3) ověření podpisu Ed25519 veřejným klíčem z Info.plist (bez platného podpisu se NIC neinstaluje)
/// 4) rozbalení, kontrola bundle id a verze, stará verze → Koš, nová na její místo, restart
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var checking = false
    @Published private(set) var status = ""
    @Published private(set) var progress: Double?

    private struct Release: Decodable {
        let tag_name: String
        let body: String?
        let html_url: String
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: String; let size: Int }
    }

    /// Oficiální zdroj aktualizací – použije se, když build nemá repo v Info.plist (např. sestavení ze ZIPu bez gitu).
    static let defaultRepo = "johnyvobruba/SSHTool"
    /// Veřejný klíč podpisu vydání (není tajný; soukromý klíč je jen u autora a v GitHub secretu).
    static let defaultPublicKey = "9aw/YZQh77i5LSRsABx7OLYvPBoOoVyxyUipZdGDr8M="

    var repo: String? {
        let r = Bundle.main.object(forInfoDictionaryKey: "SSHToolUpdateRepo") as? String ?? ""
        let ok = r.range(of: #"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
        return ok ? r : Self.defaultRepo
    }

    private var publicKey: Curve25519.Signing.PublicKey? {
        let plist = (Bundle.main.object(forInfoDictionaryKey: "SSHToolUpdatePublicKey") as? String) ?? ""
        let b64 = plist.isEmpty ? Self.defaultPublicKey : plist
        guard let raw = Data(base64Encoded: b64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Porovnání verzí 0.22.10 > 0.22.9
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Kontrola při spuštění (pokud je zapnutá) – tichá, ozve se jen při nové verzi.
    func checkOnLaunch() {
        guard Prefs.current.autoUpdateCheck, repo != nil else { return }
        let last = UserDefaults.standard.double(forKey: "SSHToolLastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }      // max. 4× denně
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check(interactive: false) }
    }

    func check(interactive: Bool) {
        guard !checking else { return }
        guard let repo, let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            if interactive { info("Aktualizace nejsou nastavené", "Tato kopie aplikace nemá nastavený GitHub repozitář (sestavení mimo git).") }
            return
        }
        checking = true; status = "Kontroluji…"
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SSHTool/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let rel = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            DispatchQueue.main.async {
                self.checking = false
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "SSHToolLastUpdateCheck")
                guard let rel, code == 200 else {
                    self.status = "Kontrola selhala"
                    if interactive {
                        self.info("Kontrola aktualizací selhala",
                                  code == 404 ? "Repozitář \(repo) zatím nemá žádný release." : (err?.localizedDescription ?? "HTTP \(code)"))
                    }
                    return
                }
                let v = rel.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                guard Self.isNewer(v, than: self.currentVersion) else {
                    self.status = "Aktuální (\(self.currentVersion))"
                    if interactive { self.info("SSHTool je aktuální", "Používáš nejnovější verzi \(self.currentVersion).") }
                    return
                }
                if !interactive, UserDefaults.standard.string(forKey: "SSHToolSkipVersion") == v { return }
                self.status = "Dostupná verze \(v)"
                self.offer(rel, version: v)
            }
        }.resume()
    }

    private func offer(_ rel: Release, version v: String) {
        let a = NSAlert()
        a.messageText = "Je dostupná nová verze SSHTool \(v)"
        let notes = (rel.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        a.informativeText = "Nainstalovaná verze: \(currentVersion)\n\n"
            + (notes.isEmpty ? "" : String(notes.prefix(1500)) + "\n\n")
            + "Při instalaci se aplikace restartuje a otevřené relace se ukončí. Stará verze se přesune do Koše."
        let zip = rel.assets.first { $0.name == "SSHTool-\(v).zip" }
        let sig = rel.assets.first { $0.name == "SSHTool-\(v).zip.sig" }
        let canInstall = zip != nil && sig != nil && publicKey != nil
        a.addButton(withTitle: canInstall ? "Nainstalovat a restartovat" : "Otevřít stránku vydání")
        a.addButton(withTitle: "Později")
        a.addButton(withTitle: "Přeskočit tuto verzi")
        if !canInstall {
            a.informativeText += "\n\nAutomatická instalace není možná (chybí podepsaný balíček nebo veřejný klíč) – stáhni ručně."
        }
        switch a.runModal() {
        case .alertFirstButtonReturn:
            if canInstall, let zip, let sig { install(zip: zip, sig: sig, version: v) }
            else if let u = URL(string: rel.html_url) { NSWorkspace.shared.open(u) }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(v, forKey: "SSHToolSkipVersion")
        default: break
        }
    }

    // MARK: Instalace

    private func install(zip: Release.Asset, sig: Release.Asset, version v: String) {
        guard let zipURL = URL(string: zip.browser_download_url), let sigURL = URL(string: sig.browser_download_url),
              zipURL.host?.hasSuffix("github.com") == true || zipURL.host?.hasSuffix("githubusercontent.com") == true,
              let key = publicKey else { return }
        status = "Stahuji \(v)…"; progress = 0
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("SSHTool-update-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        Task.detached {
            do {
                let (sigData, _) = try await URLSession.shared.data(from: sigURL)
                let (zipFile, _) = try await URLSession.shared.download(from: zipURL)
                let zipData = try Data(contentsOf: zipFile)
                guard let sigText = String(data: sigData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let signature = Data(base64Encoded: sigText),
                      key.isValidSignature(signature, for: zipData) else {
                    throw UpdateError("Podpis aktualizace je neplatný – instalace zrušena (soubor mohl být podvržen).")
                }
                let local = tmp.appendingPathComponent("SSHTool.zip")
                try zipData.write(to: local)
                try Self.run("/usr/bin/ditto", ["-x", "-k", local.path, tmp.path])
                let newApp = tmp.appendingPathComponent("SSHTool.app")
                guard let b = Bundle(url: newApp), b.bundleIdentifier == Bundle.main.bundleIdentifier,
                      (b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) == v else {
                    throw UpdateError("Balíček neobsahuje očekávanou aplikaci (bundle id / verze nesouhlasí).")
                }
                // karanténa macOS pryč ze VŠECH souborů (i z knihoven jen pro čtení a vnořené SSHTool-RDP.app),
                // jinak Gatekeeper novou verzi zablokuje („Not Opened“)
                let left = Quarantine.strip(newApp)
                guard left.isEmpty else {
                    throw UpdateError("Z nové verze nejde odstranit karanténu macOS (\(left.count) souborů, např. \(left[0].replacingOccurrences(of: newApp.path, with: "SSHTool.app"))). Instalace zrušena.\n\n" + Quarantine.manualFix)
                }
                do { try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) }
                catch { throw UpdateError("Podpis kódu nové verze neprošel kontrolou (codesign --verify) – instalace zrušena.") }
                await MainActor.run { self.replaceAndRelaunch(newApp: newApp, version: v) }
            } catch {
                await MainActor.run {
                    self.status = "Aktualizace selhala"; self.progress = nil
                    self.info("Aktualizace selhala", (error as? UpdateError)?.message ?? error.localizedDescription)
                }
            }
        }
    }

    private func replaceAndRelaunch(newApp: URL, version v: String) {
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            info("Nelze zapsat do \(parent.path)", "Nová verze je stažená a ověřená v \(newApp.path) – přesuň ji ručně.")
            NSWorkspace.shared.activateFileViewerSelecting([newApp])
            return
        }
        // běžící .app lze na macOS přesunout: stará verze → Koš (obnovitelná), nová na její místo
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: current, resultingItemURL: &trashed)
        } catch {
            info("Aktualizace selhala", "Starou verzi nelze přesunout do Koše: \(error.localizedDescription)"); return
        }
        do {
            try FileManager.default.moveItem(at: newApp, to: current)
        } catch {
            if let t = trashed as URL? { try? FileManager.default.moveItem(at: t, to: current) }   // vrátit původní
            info("Aktualizace selhala", error.localizedDescription); return
        }
        Quarantine.strip(current)        // pojistka po přesunu
        // pomocný proces: počká na ukončení této instance a spustí novou verzi
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done; open \"$0\"", current.path]
        do { try p.run() } catch { info("Nová verze je nainstalovaná", "Spusť SSHTool znovu ručně."); }
        status = "Instaluji \(v)…"
        NSApp.terminate(nil)
    }

    private struct UpdateError: Error { let message: String; init(_ m: String) { message = m } }

    nonisolated private static func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\(exe) skončil chybou \(p.terminationStatus)") }
    }

    private func info(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }
}

/// Atribut karantény macOS (com.apple.quarantine) – u nenotarizované aplikace kvůli němu Gatekeeper hlásí „Not Opened“.
enum Quarantine {
    static let attr = "com.apple.quarantine"

    static let manualFix = """
    Ruční oprava v Terminálu:
      sudo chmod -R u+w /Applications/SSHTool.app
      xattr -dr com.apple.quarantine /Applications/SSHTool.app
    """

    static func has(_ path: String) -> Bool { getxattr(path, attr, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }

    /// Odstraní karanténu z položky a všeho uvnitř. Soubory jen pro čtení dostanou zápis pro vlastníka
    /// (bez něj removexattr selže). Vrací cesty, kde karanténa zůstala.
    @discardableResult
    static func strip(_ root: URL) -> [String] {
        let fm = FileManager.default
        var paths = [root.path]
        if let e = fm.enumerator(atPath: root.path) {
            for case let rel as String in e { paths.append(root.path + "/" + rel) }
        }
        var left: [String] = []
        for p in paths where has(p) {
            if removexattr(p, attr, XATTR_NOFOLLOW) == 0 { continue }
            if let perm = (try? fm.attributesOfItem(atPath: p))?[.posixPermissions] as? NSNumber {
                try? fm.setAttributes([.posixPermissions: perm.intValue | 0o200], ofItemAtPath: p)
                if removexattr(p, attr, XATTR_NOFOLLOW) == 0 { continue }
            }
            left.append(p)
        }
        return left
    }
}
