import Foundation
import Darwin
import IOKit
import IOKit.serial
import SwiftUI
import AppKit

// MARK: - Konfigurace a porty

struct SerialConfig: Hashable {
    var path: String
    var baud: Int = 9600
    var rtscts = false

    static let baudRates = [9600, 19200, 38400, 57600, 115200]
    static let defaultBaud = 9600
}

/// Sériový port (USB-konzole) nalezený v IORegistry.
struct SerialPort: Identifiable, Hashable {
    let path: String          // /dev/cu.usbserial-XXXX
    let product: String?      // „FT232R USB UART“, „USB-Serial Controller“…
    let vendor: String?

    var id: String { path }
    var device: String { (path as NSString).lastPathComponent }
    var title: String { product ?? device }

    /// Ignorované vestavěné porty (nejsou to konzolové kabely).
    private static let ignored = ["Bluetooth-Incoming-Port", "debug-console", "wlan-debug"]

    static func scan() -> [SerialPort] {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iter) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iter) }
        var result: [SerialPort] = []
        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString,
                                                             kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String else { continue }
            if ignored.contains(where: { path.contains($0) }) { continue }
            let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            let product = IORegistryEntrySearchCFProperty(service, kIOServicePlane,
                                                          "USB Product Name" as CFString, kCFAllocatorDefault, opts) as? String
            let vendor = IORegistryEntrySearchCFProperty(service, kIOServicePlane,
                                                         "USB Vendor Name" as CFString, kCFAllocatorDefault, opts) as? String
            result.append(SerialPort(path: path, product: product, vendor: vendor))
        }
        return result.sorted { $0.path < $1.path }
    }
}

/// Hlídá připojení/odpojení USB-sériových adaptérů (sken IORegistry každé 2 s).
@MainActor
final class SerialMonitor: ObservableObject {
    @Published private(set) var ports: [SerialPort] = []
    /// Nově zastrčený port → hláška „Připojit?“.
    @Published var announce: SerialPort?

    private var timer: Timer?
    private var known: Set<String> = []

    func start() {
        guard timer == nil else { return }
        rescan(initial: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rescan(initial: false) }
        }
    }

    func rescan(initial: Bool = false) {
        let now = SerialPort.scan()
        let paths = Set(now.map(\.path))
        if !initial, let new = now.first(where: { !known.contains($0.path) }) {
            announce = new
            NSApp.requestUserAttention(.informationalRequest)
        }
        if let a = announce, !paths.contains(a.path) { announce = nil }
        known = paths
        if now != ports { ports = now }
    }
}

// MARK: - Most PTY ↔ sériový port (běží jako podproces: tatáž binárka se SSHTOOL_SERIAL_PORT)

nonisolated(unsafe) private var gBreakRequested: Int32 = 0

enum SerialBridge {
    /// Spuštěno z main.swift. Kopíruje data mezi terminálem (stdin/stdout = PTY) a portem.
    /// SIGUSR1 = poslat Break. Odpojení kabelu ukončí proces kódem 2.
    static func run(path: String, baud: Int, rtscts: Bool) -> Never {
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            say("\r\n\u{1B}[31m[Nelze otevřít \(path): \(String(cString: strerror(errno))) – není port používán jinou aplikací?]\u{1B}[0m\r\n")
            exit(1)
        }
        _ = ioctl(fd, UInt(0x2000_740D))          // TIOCEXCL – výhradní přístup

        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(baud))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB)
        t.c_cflag |= tcflag_t(CS8)
        if rtscts { t.c_cflag |= tcflag_t(CCTS_OFLOW | CRTS_IFLOW) }
        else { t.c_cflag &= ~tcflag_t(CCTS_OFLOW | CRTS_IFLOW) }
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        guard tcsetattr(fd, TCSANOW, &t) == 0 else {
            say("\r\n\u{1B}[31m[Nelze nastavit \(baud) baud na \(path)]\u{1B}[0m\r\n")
            exit(1)
        }
        _ = fcntl(fd, F_SETFL, 0)                  // zpět do blokujícího režimu

        // terminál (PTY) do raw režimu: Ctrl+C, Ctrl+Z… jdou jako bajty na zařízení
        var tin = termios()
        if tcgetattr(STDIN_FILENO, &tin) == 0 {
            cfmakeraw(&tin)
            tcsetattr(STDIN_FILENO, TCSANOW, &tin)
        }

        signal(SIGUSR1) { _ in gBreakRequested = 1 }
        say("\u{1B}[2m[Sériová konzole \(path) · \(baud) baud · 8N1 · tok: \(rtscts ? "RTS/CTS" : "žádný") · Break: ⌥⌘B]\u{1B}[0m\r\n")

        var buf = [UInt8](repeating: 0, count: 4096)
        var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)]
        while true {
            if gBreakRequested != 0 {
                gBreakRequested = 0
                tcsendbreak(fd, 0)
                say("\u{1B}[2m[Break odeslán]\u{1B}[0m\r\n")
            }
            fds[0].revents = 0; fds[1].revents = 0
            let r = poll(&fds, 2, -1)
            if r < 0 { if errno == EINTR { continue }; break }

            if fds[0].revents & Int16(POLLIN) != 0 {
                let n = read(fd, &buf, buf.count)
                if n > 0 { writeAll(STDOUT_FILENO, buf, n) }
                else if n == 0 || (errno != EINTR && errno != EAGAIN) { unplugged(path) }
            } else if fds[0].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                unplugged(path)
            }

            if fds[1].revents & Int16(POLLIN | POLLHUP) != 0 {
                let n = read(STDIN_FILENO, &buf, buf.count)
                if n > 0 { writeAll(fd, buf, n) }
                else if n == 0 { exit(0) }               // záložka zavřena
            }
        }
        exit(0)
    }

    private static func unplugged(_ path: String) -> Never {
        say("\r\n\u{1B}[33m[Sériový port \(path) byl odpojen]\u{1B}[0m\r\n")
        exit(2)
    }

    private static func say(_ s: String) {
        let b = Array(s.utf8)
        writeAll(STDOUT_FILENO, b, b.count)
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8], _ count: Int) {
        var off = 0
        bytes.withUnsafeBytes { raw in
            while off < count {
                let w = write(fd, raw.baseAddress! + off, count - off)
                if w < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
                off += w
            }
        }
    }
}

// MARK: - UI: sekce v levém panelu

struct SerialPortsSection: View {
    @EnvironmentObject private var serial: SerialMonitor
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var tabs: TabManager

    var body: some View {
        if !serial.ports.isEmpty {
            Section("SÉRIOVÉ PORTY") {
                ForEach(serial.ports) { p in
                    let baud = store.serialBaud(for: p)
                    HStack(spacing: 8) {
                        Image(systemName: "cable.connector")
                            .foregroundStyle(SwiftUI.Color(hex: SerialPort.color) ?? .yellow)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.title)
                            Text("\(p.device) · \(baud) baud").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { tabs.openSerial(p, baud: baud) }
                    .contextMenu { SerialPortMenuItems(port: p) }
                    .help("Dvojklik = připojit, pravé tlačítko = rychlost")
                }
            }
        }
    }
}

/// Položky menu pro port (kontextové menu a + v liště záložek).
struct SerialPortMenuItems: View {
    let port: SerialPort
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var tabs: TabManager

    var body: some View {
        let current = store.serialBaud(for: port)
        Button("Připojit (\(current) baud)") { tabs.openSerial(port, baud: current) }
        Menu("Připojit s rychlostí") {
            ForEach(SerialConfig.baudRates, id: \.self) { b in
                Button(b == current ? "✓ \(b) baud" : "\(b) baud") {
                    store.setSerialBaud(b, for: port)
                    tabs.openSerial(port, baud: b)
                }
            }
        }
        if let v = port.vendor { Text("Výrobce: \(v)") }
        Text(port.path)
    }
}

extension SerialPort {
    static let color = "#C9A227"
}
