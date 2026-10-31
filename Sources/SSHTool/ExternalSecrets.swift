import Foundation
import AppKit

// Hesla z externích správců hesel – načtou se až při připojení přes jejich oficiální CLI, nikam se neukládají.
//   1Password:  op://Trezor/Položka/password            (CLI „op“, odemyká aplikace 1Password / Touch ID)
//   Bitwarden:  bw://<název nebo ID položky>             (CLI „bw“; master heslo se zeptá dialogem, nebo BW_SESSION)
//   KeePassXC:  kpxc://<cesta k .kdbx>#<cesta položky>   (keepassxc-cli; heslo databáze se zeptá dialogem)
enum ExternalSecrets {
    enum Kind: String, CaseIterable, Identifiable {
        case onepassword = "op://", bitwarden = "bw://", keepassxc = "kpxc://"
        var id: String { rawValue }
        var title: String {
            switch self { case .onepassword: return "1Password"; case .bitwarden: return "Bitwarden"; case .keepassxc: return "KeePassXC" }
        }
        var example: String {
            switch self {
            case .onepassword: return "op://Infrastruktura/fw-praha/password"
            case .bitwarden: return "bw://fw-praha admin"
            case .keepassxc: return "kpxc://~/Hesla.kdbx#Síť/fw-praha"
            }
        }
        var cliCandidates: [String] {
            switch self {
            case .onepassword: return ["/opt/homebrew/bin/op", "/usr/local/bin/op"]
            case .bitwarden: return ["/opt/homebrew/bin/bw", "/usr/local/bin/bw"]
            case .keepassxc: return ["/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli", "/opt/homebrew/bin/keepassxc-cli", "/usr/local/bin/keepassxc-cli"]
            }
        }
        var install: String {
            switch self {
            case .onepassword: return "brew install 1password-cli (a v 1Password: Nastavení → Vývojář → Integrace s CLI)"
            case .bitwarden: return "brew install bitwarden-cli a jednou „bw login“"
            case .keepassxc: return "nainstaluj KeePassXC (brew install --cask keepassxc)"
            }
        }
        var cli: String? { cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } }
    }

    static func kind(of ref: String) -> Kind? { Kind.allCases.first { ref.hasPrefix($0.rawValue) } }

    struct Failure: Error { let message: String }

    /// Načte heslo. Dialogy (master heslo) běží na hlavním vlákně.
    static func fetch(_ ref: String) -> Result<String, Failure> {
        let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let k = kind(of: ref) else { return .failure(Failure(message: "Neznámý odkaz na heslo „\(ref)“.")) }
        guard let cli = k.cli else { return .failure(Failure(message: "\(k.title) CLI nenalezeno – \(k.install).")) }
        let body = String(ref.dropFirst(k.rawValue.count))
        switch k {
        case .onepassword:
            return run(cli, ["read", "--no-newline", ref])
        case .bitwarden:
            var env: [String: String] = [:]
            if ProcessInfo.processInfo.environment["BW_SESSION"] == nil {
                guard let master = askSecret("Bitwarden", "Master heslo pro odemčení trezoru (položka „\(body)“):") else {
                    return .failure(Failure(message: "Zrušeno."))
                }
                env["SSHTOOL_BW_PW"] = master
                switch run(cli, ["unlock", "--passwordenv", "SSHTOOL_BW_PW", "--raw"], env: env) {
                case .success(let token): env = ["BW_SESSION": token]
                case .failure(let f): return .failure(Failure(message: "Bitwarden: odemčení selhalo – \(f.message)"))
                }
            }
            return run(cli, ["get", "password", body], env: env)
        case .keepassxc:
            guard let hash = body.firstIndex(of: "#") else {
                return .failure(Failure(message: "KeePassXC odkaz má tvar kpxc://<cesta k .kdbx>#<cesta položky>."))
            }
            let db = (String(body[..<hash]) as NSString).expandingTildeInPath
            let entry = String(body[body.index(after: hash)...])
            guard let pw = askSecret("KeePassXC", "Heslo k databázi \((db as NSString).lastPathComponent) (položka „\(entry)“):") else {
                return .failure(Failure(message: "Zrušeno."))
            }
            return run(cli, ["show", "-q", "-s", "-a", "password", db, entry], stdin: pw + "\n")
        }
    }

    private static func run(_ exe: String, _ args: [String], env extra: [String: String] = [:], stdin: String? = nil) -> Result<String, Failure> {
        let p = Process(), out = Pipe(), err = Pipe(), inp = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.sanitizedEnvironment
        env.removeValue(forKey: "SSHTOOL_SESSION_ID")
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for (k, v) in extra { env[k] = v }
        p.environment = env
        p.standardOutput = out; p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        do { try p.run() } catch { return .failure(Failure(message: "Nelze spustit \(exe).")) }
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)); try? inp.fileHandleForWriting.close() }
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let value = String(decoding: o, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard p.terminationStatus == 0, !value.isEmpty else {
            let msg = String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(Failure(message: msg.isEmpty ? "\((exe as NSString).lastPathComponent) skončil chybou \(p.terminationStatus)." : String(msg.prefix(300))))
        }
        return .success(value)
    }

    /// Dialog s polem pro heslo (v aplikaci i v režimu askpass).
    static func askSecret(_ title: String, _ text: String) -> String? {
        @MainActor func ask() -> String? {
            let app = NSApplication.shared
            if app.activationPolicy() == .prohibited { app.setActivationPolicy(.accessory) }
            app.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            a.accessoryView = f
            a.addButton(withTitle: "OK"); a.addButton(withTitle: "Zrušit")
            a.window.initialFirstResponder = f
            a.window.level = .floating
            return a.runModal() == .alertFirstButtonReturn && !f.stringValue.isEmpty ? f.stringValue : nil
        }
        if Thread.isMainThread { return MainActor.assumeIsolated { ask() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { ask() } }
    }
}
