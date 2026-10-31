import Foundation

// Alternativní přenosy pro prohlížeč souborů. Prohlížeč posílá příkazy ve tvaru sftp dávky
// (pwd, ls -la, cd, lcd, get, put, mkdir, rename, rm, rmdir); tady se provedou jinak:
//   SCP – zařízení bez SFTP subsystému: výpis a úpravy přes ssh (ls, mkdir, mv, rm), přenosy přes `scp -O`
//         po stejném ControlMaster spojení (bez dalšího přihlášení).
//   FTP / FTPS – přes `curl` (součást macOS). Heslo jde curl přes stdin (-K -), ne v argumentech.

struct FTPConfig: Sendable {
    let host: String
    let port: Int
    let user: String
    let tls: String            // "" bez šifrování, "explicit" (AUTH TLS), "implicit" (ftps://)
    let insecure: Bool         // nekontrolovat certifikát (self-signed)
}

enum FileBackend {
    typealias Result3 = (ok: Bool, out: String, err: String)

    /// Rozdělí příkaz sftp dávky: sloveso, přepínače (-r, -p…) a argumenty (v uvozovkách podle SFTPBrowser.q).
    static func parse(_ cmd: String) -> (verb: String, flags: Set<String>, args: [String]) {
        var tokens: [String] = [], cur = "", quoted = false, esc = false, inToken = false
        for ch in cmd {
            if quoted {
                if esc { cur.append(ch); esc = false }
                else if ch == "\\" { esc = true }
                else if ch == "\"" { quoted = false }
                else { cur.append(ch) }
            } else if ch == "\"" { quoted = true; inToken = true }
            else if ch == " " { if inToken { tokens.append(cur); cur = ""; inToken = false } }
            else { cur.append(ch); inToken = true }
        }
        if inToken { tokens.append(cur) }
        guard let verb = tokens.first else { return ("", [], []) }
        var flags = Set<String>(), args: [String] = []
        for t in tokens.dropFirst() { if t.hasPrefix("-") && t.count <= 4 && args.isEmpty { flags.insert(t) } else { args.append(t) } }
        return (verb, flags, args)
    }

    static func join(_ dir: String, _ name: String) -> String {
        name.hasPrefix("/") ? name : SFTPBrowser.join(dir.isEmpty ? "." : dir, name)
    }

    /// Řetězec pro vzdálený shell v jednoduchých uvozovkách.
    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func proc(_ exe: String, _ args: [String], stdin: String? = nil, pid: Box<Int32>?) -> (Int32, String, String) {
        let p = Process(), out = Pipe(), err = Pipe(), inp = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.sanitizedEnvironment
        env.removeValue(forKey: "SSH_ASKPASS"); env.removeValue(forKey: "SSHTOOL_SESSION_ID")
        p.environment = env
        p.standardOutput = out; p.standardError = err
        if stdin != nil { p.standardInput = inp } else { p.standardInput = FileHandle.nullDevice }
        do { try p.run() } catch { return (255, "", "Nelze spustit \(exe)") }
        pid?.value = p.processIdentifier
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)); try? inp.fileHandleForWriting.close() }
        let errBox = Box<Data>(Data())
        let g = DispatchGroup(); g.enter()
        DispatchQueue.global().async { errBox.value = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: errBox.value, as: UTF8.self))
    }

    // MARK: SCP

    static func scp(_ commands: [String], cp: String, dest: String, pid: Box<Int32>?) -> Result3 {
        var cwd = "", lcd = FileManager.default.homeDirectoryForCurrentUser.path, out = ""
        func ssh(_ remoteCmd: String) -> (Int32, String, String) {
            proc(SSHBinary.path, ["-S", cp, "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-T", "--", dest, remoteCmd], pid: nil)
        }
        func scpRun(_ recursive: Bool, _ src: String, _ dst: String) -> (Int32, String, String) {
            proc("/usr/bin/scp", ["-O", "-p"] + (recursive ? ["-r"] : []) + ["-S", SSHBinary.path, "-o", "ControlPath=\(cp)",
                 "-o", "ControlMaster=no", "-o", "BatchMode=yes", "--", src, dst], pid: pid)
        }
        func local(_ p: String) -> String { p.hasPrefix("/") ? p : SFTPBrowser.join(lcd, p) }
        for c in commands {
            let (verb, flags, a) = parse(c)
            var r: (Int32, String, String) = (0, "", "")
            switch verb {
            case "pwd":
                r = ssh("pwd")
                if r.0 == 0 { out += "Remote working directory: " + r.1.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" }
            case "ls":
                let d = a.first ?? (cwd.isEmpty ? "." : cwd)
                r = ssh("LC_ALL=C ls -la -- " + shq(d.hasSuffix("/") ? d : d + "/"))
                out += r.1
            case "cd": cwd = a.first.map { join(cwd, $0) } ?? cwd
            case "lcd": lcd = a.first.map(local) ?? lcd
            case "get":
                guard let src = a.first else { continue }
                let remote = join(cwd, src)
                let target = a.count > 1 ? local(a[1]) : lcd
                r = scpRun(flags.contains("-r"), dest + ":" + shq(remote), target)
            case "put":
                guard let src = a.first else { continue }
                let target = a.count > 1 ? join(cwd, a[1]) : (cwd.isEmpty ? "." : cwd)
                r = scpRun(flags.contains("-r"), local(src), dest + ":" + shq(target))
            case "mkdir": r = ssh("mkdir -- " + shq(join(cwd, a.first ?? "")))
            case "rename" where a.count == 2: r = ssh("mv -- " + shq(join(cwd, a[0])) + " " + shq(join(cwd, a[1])))
            case "rm": r = ssh("rm -- " + shq(join(cwd, a.first ?? "")))
            case "rmdir": r = ssh("rmdir -- " + shq(join(cwd, a.first ?? "")))
            default: r = (1, "", "Nepodporovaný příkaz pro SCP: \(verb)")
            }
            if r.0 != 0 {
                let e = r.2.trimmingCharacters(in: .whitespacesAndNewlines)
                return (false, out, e.isEmpty ? "SCP: příkaz \(verb) selhal (kód \(r.0))" : e)
            }
        }
        return (true, out, "")
    }

    // MARK: FTP / FTPS (curl)

    static func ftp(_ commands: [String], _ c: FTPConfig, password: String?, pid: Box<Int32>?) -> Result3 {
        var cwd = "", lcd = FileManager.default.homeDirectoryForCurrentUser.path, out = ""
        let hostPart = c.host.contains(":") ? "[\(c.host)]" : c.host
        let base = (c.tls == "implicit" ? "ftps" : "ftp") + "://\(hostPart):\(c.port)"
        func url(_ path: String, dir: Bool = false) -> String {
            // absolutní cesta = /%2F…, jednotlivé části URL kódované
            let parts = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: ";"))) ?? String($0) }
            var u = base + "/" + (path.hasPrefix("/") ? "%2F" : "") + parts.joined(separator: "/")
            if dir, !u.hasSuffix("/") { u += "/" }
            return u
        }
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let config = c.user.isEmpty ? "" : "user = \"\(esc(c.user)):\(esc(password ?? ""))\"\n"
        let common = ["-s", "-S", "-K", "-", "--connect-timeout", "15"]
            + (c.tls == "explicit" ? ["--ssl-reqd"] : []) + (c.insecure ? ["-k"] : [])
        func curl(_ args: [String], track: Bool = false) -> (Int32, String, String) {
            proc("/usr/bin/curl", common + args, stdin: config, pid: track ? pid : nil)
        }
        func local(_ p: String) -> String { p.hasPrefix("/") ? p : SFTPBrowser.join(lcd, p) }
        func abs(_ p: String) -> String { p.hasPrefix("/") ? p : SFTPBrowser.join(cwd.isEmpty ? "/" : cwd, p) }
        for cmd in commands {
            let (verb, _, a) = parse(cmd)
            var r: (Int32, String, String) = (0, "", "")
            switch verb {
            case "pwd":
                r = curl(["-v", "-l", "-o", "/dev/null", base + "/"])
                let home = r.2.range(of: #"257 "([^"]*)""#, options: .regularExpression).map { m -> String in
                    let s = String(r.2[m]); return String(s.dropFirst(5).dropLast())
                } ?? "/"
                if r.0 == 0 { out += "Remote working directory: \(home)\n"; r.2 = "" }
                // podrobný výpis (-v) může obsahovat přihlašovací příkazy → do chybové hlášky jen řádky curl
                else { r.2 = r.2.split(whereSeparator: \.isNewline).map(String.init).filter { $0.hasPrefix("curl:") }.joined(separator: "\n") }
            case "ls":
                r = curl([url(abs(a.first ?? cwd), dir: true)])
                out += r.1
            case "cd": cwd = a.first.map(abs) ?? cwd
            case "lcd": lcd = a.first.map(local) ?? lcd
            case "get":
                guard let src = a.first else { continue }
                let remote = abs(src)
                let target = a.count > 1 ? local(a[1]) : SFTPBrowser.join(lcd, (remote as NSString).lastPathComponent)
                r = curl(["-o", target, url(remote)], track: true)
                if r.0 != 0, r.2.contains("550") || r.2.contains("not a file") { r.2 = "FTP: složky stahovat nejde – jen jednotlivé soubory." }
            case "put":
                guard let src = a.first else { continue }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: local(src), isDirectory: &isDir), isDir.boolValue {
                    r = (1, "", "FTP: složky nahrávat nejde – vyber jednotlivé soubory."); break
                }
                let target = a.count > 1 ? url(abs(a[1])) : url(cwd.isEmpty ? "/" : cwd, dir: true)
                r = curl(["-T", local(src), target], track: true)
            case "mkdir": r = curl(["-o", "/dev/null", "-Q", "MKD " + abs(a.first ?? ""), base + "/"])
            case "rename" where a.count == 2:
                r = curl(["-o", "/dev/null", "-Q", "RNFR " + abs(a[0]), "-Q", "RNTO " + abs(a[1]), base + "/"])
            case "rm": r = curl(["-o", "/dev/null", "-Q", "DELE " + abs(a.first ?? ""), base + "/"])
            case "rmdir": r = curl(["-o", "/dev/null", "-Q", "RMD " + abs(a.first ?? ""), base + "/"])
            default: r = (1, "", "Nepodporovaný příkaz pro FTP: \(verb)")
            }
            if r.0 != 0 {
                let e = r.2.trimmingCharacters(in: .whitespacesAndNewlines)
                return (false, out, e.isEmpty ? "FTP: příkaz \(verb) selhal (curl \(r.0))" : String(e.suffix(300)))
            }
        }
        return (true, out, "")
    }
}
