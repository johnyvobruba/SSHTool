import Foundation
import Darwin

// Telnet: macOS už klienta telnet nemá → tatáž binárka SSHTool v režimu „most“ (jako sériová konzole):
// PTY terminálu ↔ TCP spojení se zařízením, se základním vyjednáním voleb telnetu (RFC 854/855):
// ECHO, SGA, velikost okna (NAWS), typ terminálu (TTYPE). Ostatní volby se odmítnou.
// Telnet NENÍ šifrovaný – heslo i výstup jdou po síti čitelně.

nonisolated(unsafe) private var gTelnetWinch: sig_atomic_t = 0

enum TelnetBridge {
    private static let IAC: UInt8 = 255, DONT: UInt8 = 254, DO: UInt8 = 253, WONT: UInt8 = 252, WILL: UInt8 = 251
    private static let SB: UInt8 = 250, SE: UInt8 = 240
    private static let ECHO: UInt8 = 1, SGA: UInt8 = 3, TTYPE: UInt8 = 24, NAWS: UInt8 = 31

    static func run(host: String, port: Int) -> Never {
        say("\u{1B}[2m[Telnet \(host):\(port) – spojení NENÍ šifrované (heslo i výstup jdou sítí čitelně)]\u{1B}[0m\r\n")
        guard let sock = connectTCP(host, port) else {
            say("\r\n\u{1B}[31m[Nelze se připojit k \(host):\(port): \(String(cString: strerror(errno)))]\u{1B}[0m\r\n")
            exit(1)
        }
        // terminál (PTY) do raw režimu – Ctrl+C, šipky… jdou jako bajty na zařízení
        var tin = termios()
        if tcgetattr(STDIN_FILENO, &tin) == 0 { cfmakeraw(&tin); tcsetattr(STDIN_FILENO, TCSANOW, &tin) }
        signal(SIGWINCH) { _ in gTelnetWinch = 1 }

        var naws = false
        var state = 0                    // 0 data, 1 po IAC, 2 čeká se volba, 3 SB, 4 IAC v SB
        var cmd: UInt8 = 0
        var sb: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 8192)
        var fds = [pollfd(fd: sock, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)]

        func send(_ b: [UInt8]) { writeAll(sock, b) }
        func sendNAWS() {
            var ws = winsize()
            guard withUnsafeMutablePointer(to: &ws, { ioctl(STDIN_FILENO, UInt(0x4008_7468), $0) }) == 0 else { return }  // TIOCGWINSZ
            var p: [UInt8] = [IAC, SB, NAWS]
            for v in [ws.ws_col, ws.ws_row] {
                for byte in [UInt8(v >> 8), UInt8(v & 0xFF)] { p.append(byte); if byte == IAC { p.append(IAC) } }
            }
            send(p + [IAC, SE])
        }

        while true {
            if gTelnetWinch != 0 { gTelnetWinch = 0; if naws { sendNAWS() } }
            fds[0].revents = 0; fds[1].revents = 0
            let r = poll(&fds, 2, 500)
            if r < 0 { if errno == EINTR { continue }; break }
            if r == 0 { continue }

            if fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let n = read(sock, &buf, buf.count)
                if n <= 0 { say("\r\n\u{1B}[33m[Telnet spojení ukončeno]\u{1B}[0m\r\n"); exit(0) }
                var out: [UInt8] = []
                for b in buf[0..<n] {
                    switch state {
                    case 0:
                        if b == IAC { state = 1 } else { out.append(b) }
                    case 1:
                        switch b {
                        case IAC: out.append(IAC); state = 0
                        case WILL, WONT, DO, DONT: cmd = b; state = 2
                        case SB: sb = []; state = 3
                        default: state = 0                       // NOP, GA, AYT…
                        }
                    case 2:
                        switch cmd {
                        case WILL: send([IAC, (b == ECHO || b == SGA) ? DO : DONT, b])
                        case DO:
                            if b == NAWS { send([IAC, WILL, NAWS]); naws = true; sendNAWS() }
                            else if b == TTYPE || b == SGA { send([IAC, WILL, b]) }
                            else { send([IAC, WONT, b]) }
                        default: break                           // WONT / DONT – bez odpovědi (žádné smyčky)
                        }
                        state = 0
                    case 3:
                        if b == IAC { state = 4 } else { sb.append(b) }
                    default:
                        if b == SE {
                            if sb.count >= 2, sb[0] == TTYPE, sb[1] == 1 {       // TTYPE SEND
                                send([IAC, SB, TTYPE, 0] + Array("XTERM-256COLOR".utf8) + [IAC, SE])
                            }
                            state = 0
                        } else { if b == IAC { sb.append(IAC) }; state = 3 }
                    }
                }
                if !out.isEmpty { writeAll(STDOUT_FILENO, out) }
            }

            if fds[1].revents & Int16(POLLIN | POLLHUP) != 0 {
                let n = read(STDIN_FILENO, &buf, buf.count)
                if n <= 0 { close(sock); exit(0) }               // záložka zavřena
                var out: [UInt8] = []
                for b in buf[0..<n] {
                    if b == IAC { out += [IAC, IAC] }
                    else if b == 13 { out += [13, 0] }           // Enter = CR NUL (RFC 854)
                    else { out.append(b) }
                }
                send(out)
            }
        }
        exit(0)
    }

    private static func connectTCP(_ host: String, _ port: Int) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(first) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s >= 0 {
                if connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 {
                    var one: Int32 = 1
                    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                    return s
                }
                close(s)
            }
            ai = a.pointee.ai_next
        }
        return nil
    }

    private static func say(_ s: String) { writeAll(STDOUT_FILENO, Array(s.utf8)) }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var off = 0
        bytes.withUnsafeBytes { raw in
            while off < bytes.count {
                let w = write(fd, raw.baseAddress! + off, bytes.count - off)
                if w < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
                off += w
            }
        }
    }
}
