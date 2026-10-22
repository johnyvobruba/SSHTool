import Foundation
import SwiftUI
import AppKit

// Wireshark z SSH relace:
//  1) Živě: tcpdump -U -w - na serveru → přes stejné (už přihlášené) SSH spojení → lokální Wireshark -k -i -
//     (obdoba `ssh host tcpdump -U -s0 -w - 'not port 22' | wireshark -k -i -`).
//  2) Soubor: stáhne zachycený pcap ze serveru (přes stejné spojení) a otevře ho ve Wiresharku.
// Vlastní SSH provoz relace se z živého odchytu vylučuje přesně podle $SSH_CLIENT (IP a port klienta).

enum WiresharkApp {
    static var url: URL? {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.wireshark.Wireshark") { return u }
        let p = "/Applications/Wireshark.app"
        return FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
    }

    static var binary: URL? { url?.appendingPathComponent("Contents/MacOS/Wireshark") }

    @MainActor static func missingAlert() {
        let a = NSAlert()
        a.messageText = "Wireshark není nainstalovaný"
        a.informativeText = "Nainstaluj Wireshark pro macOS (wireshark.org) do složky Aplikace a zkus to znovu."
        a.addButton(withTitle: "Otevřít wireshark.org")
        a.addButton(withTitle: "Zavřít")
        if a.runModal() == .alertFirstButtonReturn, let u = URL(string: "https://www.wireshark.org/download.html") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Lokální složka pro stažené odchyty (práva 700 – obsahují data provozu).
    static var captureDir: URL {
        let d = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSHTool-captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return d
    }
}

/// Běžící živý odchyt: ssh (stdout = pcap stream) → Wireshark (stdin).
final class LiveCapture: ObservableObject, @unchecked Sendable {
    @Published private(set) var bytes = 0
    @Published private(set) var running = true
    @Published private(set) var message: String?
    let title: String

    private var ssh: Process?
    private var ws: Process?
    private let lock = NSLock()
    private var count = 0
    private var lastPublish = Date.distantPast
    private var errText = ""

    init(title: String) { self.title = title }

    func start(controlPath: String, destination: String, remote: String) throws {
        guard let wsBin = WiresharkApp.binary else { throw NSError(domain: "SSHTool", code: 1) }
        let sshOut = Pipe(), sshErr = Pipe(), wsIn = Pipe()

        let w = Process()
        w.executableURL = wsBin
        w.arguments = ["-k", "-i", "-", "-o", "gui.window_title:SSHTool – \(title)"]
        w.standardInput = wsIn
        w.standardOutput = FileHandle.nullDevice
        w.standardError = FileHandle.nullDevice
        w.terminationHandler = { [weak self] _ in self?.stop() }      // Wireshark zavřen → ukončit odchyt

        let s = Process()
        s.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        s.arguments = ["-S", controlPath, "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-T", "--", destination, remote]
        var env = ProcessInfo.sanitizedEnvironment
        env.removeValue(forKey: "SSH_ASKPASS")
        s.environment = env
        s.standardInput = FileHandle.nullDevice
        s.standardOutput = sshOut
        s.standardError = sshErr

        let writer = wsIn.fileHandleForWriting
        sshOut.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; try? writer.close(); return }
            do { try writer.write(contentsOf: d) } catch { h.readabilityHandler = nil; return }
            self?.added(d.count)
        }
        sshErr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            self?.lock.lock(); if (self?.errText.count ?? 0) < 4000 { self?.errText += String(decoding: d, as: UTF8.self) }; self?.lock.unlock()
        }
        s.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock(); let err = self.errText; let n = self.count; self.lock.unlock()
            let last = err.split(whereSeparator: \.isNewline).map(String.init)
                .last { !$0.contains("listening on") && !$0.contains("packets captured") && !$0.contains("received by filter") && !$0.contains("dropped by kernel") }
            let summary = err.split(whereSeparator: \.isNewline).map(String.init).filter { $0.contains("packets captured") }.first
            DispatchQueue.main.async {
                self.running = false
                self.bytes = n
                if n == 0 { self.message = last ?? "Odchyt skončil bez dat (kód \(p.terminationStatus))" }
                else { self.message = summary.map { "Hotovo – \($0)" } ?? "Hotovo" }
            }
        }

        try w.run()
        ws = w
        do { try s.run(); ssh = s } catch { w.terminate(); throw error }
    }

    private func added(_ n: Int) {
        lock.lock(); count += n; let c = count
        let now = Date(); let publish = now.timeIntervalSince(lastPublish) > 0.5
        if publish { lastPublish = now }
        lock.unlock()
        if publish { DispatchQueue.main.async { self.bytes = c } }
    }

    /// Zastaví odchyt na serveru (Wireshark zůstane otevřený se zachycenými pakety).
    func stop() {
        if let s = ssh, s.isRunning { s.terminate() }
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

@MainActor
extension TabManager {
    private func confirmCapture(_ t: TerminalTab, _ what: String) -> Bool {
        guard t.session.envTag == "prod" else { return true }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "\(what) na produkčním zařízení?"
        a.informativeText = "\(t.session.name) (\(t.session.host)) je označený jako PROD. Odchyt zatěžuje CPU a výstup obsahuje data provozu."
        a.addButton(withTitle: "Pokračovat"); a.addButton(withTitle: "Zrušit")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Živý odchyt do lokálního Wiresharku přes stejné SSH spojení.
    func startLiveWireshark(_ m: CaptureModel) {
        guard let t = selected, t.running, let cp = t.view.controlPath else { NSSound.beep(); return }
        guard WiresharkApp.binary != nil else { WiresharkApp.missingAlert(); return }
        guard let remote = m.liveRemoteCommand, confirmCapture(t, "Spustit živý odchyt") else { return }
        liveCapture?.stop()
        let lc = LiveCapture(title: "\(t.session.name) (\(t.session.host))")
        do {
            try lc.start(controlPath: cp, destination: t.session.destinationString, remote: remote)
            liveCapture = lc
        } catch {
            let a = NSAlert(); a.messageText = "Odchyt nelze spustit"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }

    /// Stáhne soubor s odchytem ze serveru (přes stejné spojení) a otevře ho ve Wiresharku.
    func downloadCaptureToWireshark(_ m: CaptureModel) {
        guard let t = selected, t.running, let cp = t.view.controlPath else { NSSound.beep(); return }
        guard let app = WiresharkApp.url else { WiresharkApp.missingAlert(); return }
        let remotePath = m.file.trimmingCharacters(in: .whitespaces)
        guard remotePath.range(of: #"^/[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil else { NSSound.beep(); return }
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let ext = m.tool == .tcpdump ? "pcap" : "cap"
        let safeHost = t.session.host.replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "_", options: .regularExpression)
        let local = WiresharkApp.captureDir.appendingPathComponent("\(safeHost)-\(df.string(from: Date())).\(ext)")
        let dest = t.session.destinationString
        let sudo = m.useSudo ? "sudo -n " : ""
        DispatchQueue.global(qos: .userInitiated).async {
            FileManager.default.createFile(atPath: local.path, contents: nil, attributes: [.posixPermissions: 0o600])
            guard let fh = try? FileHandle(forWritingTo: local) else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-S", cp, "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-T", "--", dest, "\(sudo)cat \(remotePath)"]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = fh
            let err = Pipe(); p.standardError = err
            do { try p.run() } catch { return }
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            try? fh.close()
            let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int) ?? 0
            DispatchQueue.main.async {
                if p.terminationStatus == 0, size > 0 {
                    NSWorkspace.shared.open([local], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    let a = NSAlert(); a.messageText = "Stažení se nepodařilo"
                    a.informativeText = e.isEmpty ? "Soubor \(remotePath) je prázdný nebo neexistuje (odchyt ještě běží?)." : e
                    a.runModal()
                }
            }
        }
    }
}

/// Indikátor živého odchytu ve stavovém řádku.
struct LiveCaptureBadge: View {
    @ObservedObject var capture: LiveCapture
    @EnvironmentObject private var tabs: TabManager

    var body: some View {
        HStack(spacing: 6) {
            if capture.running {
                Circle().fill(UI.error).frame(width: 7, height: 7)
                Text("Wireshark live · \(capture.sizeText)").monospacedDigit()
                Button("Zastavit") { capture.stop() }.buttonStyle(.plain).foregroundStyle(UI.accent)
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(UI.textTertiary)
                Text(capture.message ?? "Odchyt ukončen").lineLimit(1)
                Button { tabs.liveCapture = nil } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(UI.textTertiary)
            }
        }
        .help("Živý odchyt do Wiresharku: \(capture.title)")
    }
}
