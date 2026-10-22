import Foundation
import Network

/// „Otestovat připojení“ v editoru serveru. Každý řádek odpovídá skutečně provedené kontrole:
/// 1) DNS překlad, 2) TCP spojení + SSH banner, 3) ověření klíče serveru proti known_hosts,
/// 4) autentizace (ssh -o BatchMode=yes, bez interakce). Test NIKDY nemění known_hosts
/// (StrictHostKeyChecking=yes) a nepoužívá heslo – to se ověří až při skutečném připojení.
@MainActor
final class ConnectionTester: ObservableObject {
    enum Status { case pending, running, ok, fail, skipped }
    struct Step: Identifiable {
        let id: Int
        let title: String
        var status: Status = .pending
        var detail = ""
    }

    @Published var steps: [Step] = []
    @Published var running = false

    func run(_ s: SSHSession) {
        guard !running else { return }
        running = true
        steps = [Step(id: 0, title: "DNS / IP adresa"),
                 Step(id: 1, title: "TCP port \(s.port)"),
                 Step(id: 2, title: "SSH handshake (banner)"),
                 Step(id: 3, title: "Klíč serveru (known_hosts)"),
                 Step(id: 4, title: "Autentizace")]
        let host = s.host.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        let port = s.port
        let args = s.sshArguments()
        let viaJump = !s.jumpHost.isEmpty
        let pwd = s.auth == .password || s.auth == .interactive

        Task {
            if viaJump {
                for i in 0...2 { set(i, .skipped, "Přes jump host \(s.jumpHost) – ověří se v SSH testu") }
            } else {
                set(0, .running, "")
                let ip = await Task.detached { Self.resolve(host) }.value
                guard let ip else {
                    set(0, .fail, "Název „\(host)“ nelze přeložit (DNS) – zkontroluj název nebo VPN")
                    for i in 1...4 { set(i, .skipped, "") }
                    running = false; return
                }
                set(0, .ok, ip == host ? "IP adresa \(ip)" : "\(host) → \(ip)")
                set(1, .running, ""); set(2, .running, "")
                let b = await Self.banner(host: host, port: port)
                set(1, b.tcp ? .ok : .fail, b.tcp ? "Spojení navázáno" : b.msg)
                set(2, b.ssh ? .ok : (b.tcp ? .fail : .skipped), b.tcp ? b.msg : "")
                if !b.ssh { set(3, .skipped, ""); set(4, .skipped, ""); running = false; return }
            }
            set(3, .running, ""); set(4, .running, "")
            let r = await Task.detached { Self.sshProbe(args) }.value
            let err = r.err
            if r.code != 255 {
                set(3, .ok, "Klíč odpovídá záznamu v known_hosts")
                set(4, .ok, "Přihlášení bez interakce proběhlo")
            } else if err.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
                set(3, .fail, "Klíč serveru se ZMĚNIL! Možný útok MITM nebo reinstalace – ověř s administrátorem.")
                set(4, .skipped, "")
            } else if err.contains("Host key verification failed") || err.contains("No ED25519 host key") || err.contains("host key for") {
                set(3, .fail, "Klíč není v known_hosts – při prvním připojení ověř otisk (fingerprint) a potvrď.")
                set(4, .skipped, "Neověřeno (bez důvěryhodného klíče serveru)")
            } else if err.contains("Permission denied") || err.contains("Too many authentication failures") {
                set(3, .ok, "Klíč odpovídá záznamu v known_hosts")
                if pwd { set(4, .skipped, "Heslo se při testu nezadává – ověří se při připojení") }
                else { set(4, .fail, "Server odmítl klíč / agenta: " + Self.lastLine(err)) }
            } else {
                let l = Self.lastLine(err)
                if viaJump, l.lowercased().contains("jump") || l.contains("Connection closed by UNKNOWN") {
                    set(3, .skipped, ""); set(4, .fail, "Jump host: " + l)
                } else {
                    set(3, .skipped, "")
                    set(4, .fail, l.isEmpty ? "ssh skončil chybou (255)" : l)
                }
            }
            running = false
        }
    }

    private func set(_ i: Int, _ st: Status, _ detail: String) {
        guard steps.indices.contains(i) else { return }
        steps[i].status = st
        steps[i].detail = detail
    }

    nonisolated static func lastLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map(String.init).last { !$0.hasPrefix("Warning:") } ?? ""
    }

    // MARK: DNS

    nonisolated static func resolve(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buf, socklen_t(buf.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return host }
        return String(cString: buf)
    }

    // MARK: TCP + SSH banner

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    /// Vláknově bezpečný příznak (stav TCP spojení) – bez zachycené měnitelné proměnné.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var v = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); v = newValue; lock.unlock() }
        }
    }

    nonisolated static func banner(host: String, port: Int) async -> (tcp: Bool, ssh: Bool, msg: String) {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return (false, false, "Neplatný port") }
        return await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let q = DispatchQueue(label: "sshtool.conntest")
            let once = Once()
            let tcpUp = Flag()
            let finish: (Bool, String) -> Void = { ssh, msg in
                guard once.claim() else { return }
                conn.cancel()
                cont.resume(returning: (tcpUp.value, ssh, msg))
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    tcpUp.value = true
                    conn.receive(minimumIncompleteLength: 4, maximumLength: 255) { data, _, _, _ in
                        guard let data, let s = String(data: data, encoding: .utf8) else {
                            finish(false, "Server neposlal SSH banner (jiná služba nebo zablokováno IPS)"); return
                        }
                        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
                        if line.hasPrefix("SSH-") { finish(true, line) }
                        else { finish(false, "Port \(port) odpovídá, ale nejde o SSH") }
                    }
                case .failed(let e), .waiting(let e):
                    let d = e.localizedDescription
                    finish(false, d.contains("refused") || d.contains("odmítnut")
                           ? "Spojení odmítnuto – na portu \(port) neběží SSH nebo ho blokuje firewall (RST)" : d)
                default: break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + 6) {
                finish(false, tcpUp.value ? "Bez SSH banneru do 6 s" : "Bez odpovědi do 6 s – port \(port) je filtrovaný (firewall DROP) nebo host neběží")
            }
        }
    }

    // MARK: SSH (BatchMode)

    nonisolated static func sshProbe(_ args: [String]) -> (code: Int32, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // první -o vyhrává: striktní kontrola klíče (žádný zápis do known_hosts), žádná interakce
        p.arguments = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8",
                       "-o", "NumberOfPasswordPrompts=0", "-T"] + args + ["exit"]
        var env = ProcessInfo.sanitizedEnvironment
        env.removeValue(forKey: "SSH_ASKPASS"); env.removeValue(forKey: "SSHTOOL_SESSION_ID")
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe
        do { try p.run() } catch { return (255, "Nelze spustit /usr/bin/ssh") }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timer)
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        let err = String(decoding: data, as: UTF8.self)
        // ukončeno časovačem / signálem ≠ úspěch
        if p.terminationReason == .uncaughtSignal { return (255, err + "\nTest překročil časový limit 20 s") }
        return (p.terminationStatus, err)
    }
}
