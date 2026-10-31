import Foundation

/// Klient ssh: systémový /usr/bin/ssh, nebo vlastní (např. Homebrew OpenSSH) z Nastavení → Obecné.
/// Vlastní klient pomůže, když systémové OpenSSH po aktualizaci macOS starý algoritmus úplně odstraní.
enum SSHBinary {
    static let system = "/usr/bin/ssh"
    /// Nastavuje AppStore při načtení / změně nastavení (čte se i mimo hlavní vlákno).
    nonisolated(unsafe) static var custom = ""

    static var path: String {
        let c = (custom as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty, FileManager.default.isExecutableFile(atPath: c), (c as NSString).lastPathComponent == "ssh" { return c }
        return system
    }

    /// `ssh -V` (verze OpenSSH) – pro nastavení.
    static func version(_ path: String) -> String? {
        let p = Process(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-V"]
        p.standardError = err; p.standardOutput = err; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let s = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return s.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    // MARK: Starší zařízení (legacy algoritmy)

    nonisolated(unsafe) private static var cache: [String: Set<String>] = [:]
    private static let lock = NSLock()

    /// Algoritmy, které daná binárka ssh zná (`ssh -Q kex|cipher|mac|key`). Neznámý název v -o by ssh odmítl.
    static func supported(_ query: String) -> Set<String> {
        let bin = path, key = bin + "|" + query
        lock.lock(); if let c = cache[key] { lock.unlock(); return c }; lock.unlock()
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-Q", query]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        var set = Set<String>()
        if (try? p.run()) != nil {
            let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            set = Set(s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        }
        lock.lock(); cache[key] = set; lock.unlock()
        return set
    }

    /// Volby -o pro staré Cisco IOS/ASA, F5, starší Gaia… – jen algoritmy, které klient opravdu zná,
    /// přidané („+“) k výchozím, takže moderní algoritmy mají dál přednost.
    static var legacyOptions: [String] {
        func plus(_ name: String, _ query: String, _ wanted: [String]) -> [String] {
            let have = supported(query)
            let list = wanted.filter { have.contains($0) }
            return list.isEmpty ? [] : ["-o", "\(name)=+" + list.joined(separator: ",")]
        }
        return plus("KexAlgorithms", "kex", ["diffie-hellman-group14-sha1", "diffie-hellman-group-exchange-sha1", "diffie-hellman-group1-sha1"])
            + plus("HostKeyAlgorithms", "key", ["ssh-rsa", "ssh-dss"])
            + plus("PubkeyAcceptedAlgorithms", "key", ["ssh-rsa"])
            + plus("Ciphers", "cipher", ["aes128-cbc", "aes192-cbc", "aes256-cbc", "3des-cbc"])
            + plus("MACs", "mac", ["hmac-sha1"])
    }
}
