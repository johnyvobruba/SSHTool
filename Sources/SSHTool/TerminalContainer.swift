import AppKit
import SwiftTerm

/// Typ záložky.
enum TabKind: String, Codable {
    case ssh, sftp, local, serial
}

/// Terminál jednoho SSH spojení (jedna záložka).
///
/// Proč ne LocalProcessTerminalView: ve SwiftTermu 1.99 jde výstup procesu přes interní
/// adaptér rovnou do parseru a přepsaná `dataReceived` se nikdy nezavolá → zvýraznění nefungovalo.
/// Proto čisté `TerminalView` + vlastní `LocalProcess`, jehož delegát (ProcessAdapter)
/// prožene každý chunk highlighterem a teprve pak ho pošle do terminálu.
final class SSHTerminalView: TerminalView, TerminalViewDelegate {
    // Optional (ne „!“): TerminalView volá delegáta už během init (změna fontu → sizeChanged).
    private(set) var process: LocalProcess?
    private var adapter: ProcessAdapter?
    private(set) var isRunning = false
    var onTerminated: (@MainActor (Int32?) -> Void)?
    /// Klik do terminálu (rozdělené zobrazení → přesun fokusu na tento panel).
    var onFocus: (@MainActor () -> Void)?
    /// První data od procesu (pro stav „Připojování…“ → „Připojeno“).
    var onFirstOutput: (@MainActor () -> Void)?
    /// Vstup od uživatele (psaní, vložení) – pro broadcast do dalších relací.
    var onUserInput: (@MainActor (ArraySlice<UInt8>) -> Void)?

    /// Pošle data procesu bez dalšího šíření (cíl broadcastu).
    func sendRaw(_ data: ArraySlice<UInt8>) {
        guard isRunning else { return }
        process?.send(data: data)
    }

    // MARK: Hledání ve výstupu (lišta SwiftTermu)

    func showFind() { findAction(.showFindPanel) }
    func findAgain(forward: Bool) { findAction(forward ? .next : .previous) }

    private func findAction(_ a: NSFindPanelAction) {
        let item = NSMenuItem()
        item.tag = Int(a.rawValue)
        performFindPanelAction(item)
    }

    fileprivate func firstOutput() { onFirstOutput?() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSSH()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSSH()
    }

    private func configureSSH() {
        // Nejdřív proces, pak delegát a font – setter fontu hned volá sizeChanged.
        let a = ProcessAdapter(view: self)
        adapter = a
        // Výkon: čtení z PTY a zvýrazňování běží na vlastní sériové frontě každé relace (ne na hlavním
        // vlákně). Do terminálu se data předávají dávkově jedním skokem na hlavní vlákno.
        process = LocalProcess(delegate: a, dispatchQueue: a.queue)
        terminalDelegate = self
        applyFontSettings()
        TabbyTheme.apply(to: self)
        changeScrollback(Prefs.current.scrollback)      // výchozích 500 řádků je na výpisy logů málo
        registerDrop()
        // selektorový observer se při uvolnění view odhlásí sám (macOS 10.11+)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollbackSettingChanged(_:)),
                                               name: AppSettings.scrollbackChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeSettingChanged(_:)),
                                               name: AppSettings.fontSizeChanged, object: nil)
        // změna profilu: jen přebarvení – relace ani historie se nemění
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged(_:)),
                                               name: ThemeStore.changed, object: nil)
    }

    @objc private func fontSizeSettingChanged(_ note: Notification) { applyFontSettings() }
    @objc private func themeChanged(_ note: Notification) { TabbyTheme.apply(to: self) }

    /// Písmo (SF Mono / zvolené), velikost a řádkování z nastavení.
    private func applyFontSettings() {
        let p = Prefs.current
        let size = CGFloat(p.fontSize)
        font = (p.fontName.isEmpty ? nil : NSFont(name: p.fontName, size: size))
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        lineSpacing = CGFloat(p.lineSpacing)
        // Option = macOS znaky (⌥2 = @ na české klávesnici). Meta (Esc+) jen na přání v Nastavení.
        optionAsMetaKey = p.optionAsMeta
    }

    @objc private func scrollbackSettingChanged(_ note: Notification) {
        changeScrollback(Prefs.current.scrollback)
    }

    private(set) var kind: TabKind = .ssh
    /// Socket ControlMaster hlavního ssh (jen .ssh) – přes něj jede monitor bez nového přihlášení.
    private(set) var controlPath: String?
    private(set) var session: SSHSession?

    func start(kind: TabKind, session: SSHSession, serial: SerialConfig? = nil) {
        guard let process else { return }
        self.kind = kind
        self.session = session
        // Celé prostředí GUI aplikace (kvůli SSH_AUTH_SOCK, HOME, PATH…) + TERM.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if kind == .ssh || kind == .sftp, session.usesStoredPassword, let exe = Bundle.main.executablePath {
            env["SSH_ASKPASS"] = exe                 // ssh (i ssh pod sftp) zavolá naši vlastní binárku…
            env["SSH_ASKPASS_REQUIRE"] = "force"     // …i když má TTY (OpenSSH 8.4+)
            env["SSHTOOL_SESSION_ID"] = session.id.uuidString
        }
        let envList = env.map { "\($0.key)=\($0.value)" }
        isRunning = true
        switch kind {
        case .ssh:
            let cp = RemoteMonitor.controlPath(for: UUID())
            controlPath = cp
            process.startProcess(executable: "/usr/bin/ssh", args: session.sshArguments(controlPath: cp),
                                 environment: envList, execName: "ssh")
        case .sftp:
            // SFTP záložka = grafický prohlížeč souborů. ssh tu jen drží přihlášené spojení (ControlMaster, -N);
            // přihlášení (heslo / OTP / potvrzení klíče serveru) probíhá v tomto terminálu pod prohlížečem.
            let cp = RemoteMonitor.controlPath(for: UUID())
            controlPath = cp
            feed(text: "\u{1B}[2m[Přihlašování pro prohlížeč souborů – případné heslo / OTP zadej sem. Soubory se zobrazí nahoře.]\u{1B}[0m\r\n")
            process.startProcess(executable: "/usr/bin/ssh", args: ["-N"] + session.sshArguments(controlPath: cp),
                                 environment: envList, execName: "ssh")
        case .local:
            let shell = env["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            process.startProcess(executable: shell, args: ["-l"], environment: envList,
                                 execName: (shell as NSString).lastPathComponent,
                                 currentDirectory: NSHomeDirectory())
        case .serial:
            // most PTY ↔ /dev/cu.* = naše vlastní binárka v sériovém režimu (viz SerialBridge)
            guard let serial, let exe = Bundle.main.executablePath else {
                feed(text: "\u{1B}[31m[Chybí konfigurace sériového portu]\u{1B}[0m\r\n")
                isRunning = false
                return
            }
            env["SSHTOOL_SERIAL_PORT"] = serial.path
            env["SSHTOOL_SERIAL_BAUD"] = String(serial.baud)
            env["SSHTOOL_SERIAL_FLOW"] = serial.rtscts ? "rtscts" : "none"
            env.removeValue(forKey: "SSHTOOL_SESSION_ID")
            process.startProcess(executable: exe, args: [],
                                 environment: env.map { "\($0.key)=\($0.value)" },
                                 execName: "sshtool-serial")
        }
    }

    func stop() {
        stopLogging()
        guard isRunning else { return }
        process?.terminate()
    }

    // MARK: Klávesové zkratky terminálu

    /// ⌘L: vyčistí obrazovku i historii lokálně a pošle Ctrl+L, aby shell znovu vykreslil prompt.
    func clearScreen() {
        clearScrollback()
        feed(text: "\u{1B}[H\u{1B}[2J")
        sendControl(0x0C)
    }

    /// Sériová konzole: pošle Break (most dostane SIGUSR1 a zavolá tcsendbreak).
    func sendBreak() {
        guard kind == .serial, isRunning, let pid = process?.shellPid, pid > 0 else { return }
        kill(pid, SIGUSR1)
    }

    /// Pošle řídicí znak (např. 0x12 = Ctrl+R – hledání v historii příkazů).
    func sendControl(_ byte: UInt8) {
        guard isRunning else { return }
        process?.send(data: [byte][...])
    }

    // MARK: Logování do souboru

    var isLogging: Bool { adapter?.logger != nil }
    private(set) var logURL: URL?

    /// Spustí logování výstupu; vrací false, když soubor nejde vytvořit.
    @discardableResult
    func startLogging() -> Bool {
        guard let adapter, adapter.logger == nil, let session else { return isLogging }
        guard let logger = SessionLogger(settings: Prefs.current, session: session, kind: kind) else {
            feed(text: "\r\n\u{1B}[31m[Log nelze vytvořit ve složce \(Prefs.current.logDirectory) – zkontroluj ji v Nastavení (⌘,)]\u{1B}[0m\r\n")
            return false
        }
        adapter.logger = logger
        logURL = logger.url
        feed(text: "\r\n\u{1B}[2m[Logování: \(logger.url.path)]\u{1B}[0m\r\n")
        return true
    }

    func stopLogging() {
        guard let logger = adapter?.logger else { return }
        logger.close()
        adapter?.logger = nil
        feed(text: "\r\n\u{1B}[2m[Logování ukončeno]\u{1B}[0m\r\n")
    }

    // MARK: Myš: kopírování výběrem, vložení pravým tlačítkem (jako PuTTY / Tabby)

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard Prefs.current.copyOnSelect, selectionActive,
              let text = getSelection(), !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    override func rightMouseDown(with event: NSEvent) {
        onFocus?()
        guard Prefs.current.rightClickPaste else { return super.rightMouseDown(with: event) }
        guard isRunning else { return }
        paste(self)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard Prefs.current.rightClickPaste else { return super.rightMouseUp(with: event) }
    }

    fileprivate func processEnded(_ code: Int32?) {
        isRunning = false
        if let logger = adapter?.logger {
            logger.writeLine("\n=== proces ukončen, kód \(code.map { String($0) } ?? "?") ===")
            logger.close()
            adapter?.logger = nil
        }
        let c = code.map { String($0) } ?? "?"
        feed(text: "\r\n\u{1B}[2m[Spojení ukončeno, kód \(c) – ⌘R znovu připojí]\u{1B}[0m\r\n")
        if kind == .sftp, let code, code != 0 {
            feed(text: "\u{1B}[33mSFTP se nepodařilo. Častá příčina: server nemá povolený SFTP subsystém, nebo uživatel nemá shell,\r\n"
                     + "který SFTP umí. Check Point Gaia: uživatel potřebuje shell /bin/bash (clish: set user <jméno> shell /bin/bash),\r\n"
                     + "s výchozím clish SFTP i SCP selžou.\u{1B}[0m\r\n")
        }
        onTerminated?(code)
    }

    // MARK: Drag & drop souborů z Finderu → vloží (escapované) cesty, např. pro put / scp

    private func registerDrop() { registerForDraggedTypes([.fileURL]) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isRunning ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isRunning,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let text = urls.map { Self.escapePath($0.path) }.joined(separator: " ") + " "
        process?.send(data: Array(text.utf8)[...])
        return true
    }

    /// Escapování zpětným lomítkem – funguje v shellu i v sftp.
    static func escapePath(_ p: String) -> String {
        let special = Set(" '\"\\$`!&*()[]{};<>?|#~")
        return String(p.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard isRunning else { return }
        process?.send(data: data)
        onUserInput?(data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let adapter, let process else { return }
        var ws = adapter.getWindowSize()
        _ = process.updateWindowSize(&ws)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Delegát LocalProcessu: výstup ssh → highlighter → terminál.
private final class ProcessAdapter: LocalProcessDelegate, @unchecked Sendable {
    weak var view: SSHTerminalView?
    private let lock = NSLock()
    private var _logger: SessionLogger?
    var logger: SessionLogger? {
        get { lock.lock(); defer { lock.unlock() }; return _logger }
        set { lock.lock(); _logger = newValue; lock.unlock() }
    }
    /// Sériová fronta relace: čtení PTY, log a zvýraznění mimo hlavní vlákno.
    let queue = DispatchQueue(label: "sshtool.session.io", qos: .userInitiated)
    private let highlighter = AnsiHighlighter()      // používá se jen na `queue`
    private var sawOutput = false
    private var pending: [UInt8] = []                // čeká na předání terminálu (chráněno lockem)
    private var flushScheduled = false

    init(view: SSHTerminalView) { self.view = view }

    func dataReceived(slice: ArraySlice<UInt8>) {
        if !sawOutput {
            sawOutput = true
            let v = view
            DispatchQueue.main.async { v?.firstOutput() }
        }
        logger?.write(slice)                 // do logu jde výstup serveru bez našeho zvýraznění
        let out = highlighter.process(slice)
        guard !out.isEmpty else { return }
        lock.lock()
        pending.append(contentsOf: out)
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        // Dávkování: při velkém výstupu jeden skok na hlavní vlákno místo stovek.
        if schedule { DispatchQueue.main.async { [weak self] in self?.flush() } }
    }

    /// Hlavní vlákno: předá nashromážděná data terminálu.
    func flush() {
        lock.lock()
        let data = pending
        pending.removeAll(keepingCapacity: true)
        flushScheduled = false
        lock.unlock()
        guard !data.isEmpty else { return }
        view?.feed(byteArray: data[...])
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        // na hlavní frontě až po posledních datech (FIFO) → text „Spojení ukončeno“ je vždy na konci
        DispatchQueue.main.async { [weak self] in
            self?.flush()
            self?.view?.processEnded(exitCode)
        }
    }

    func getWindowSize() -> winsize {
        guard let d = view?.terminalDimensions, d.cols > 0, d.rows > 0 else {
            return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        }
        return winsize(ws_row: UInt16(d.rows), ws_col: UInt16(d.cols), ws_xpixel: 0, ws_ypixel: 0)
    }
}

/// Schéma terminálu „Slate“ (pozadí #14161B, ANSI paleta laděná k akcentu #7799E8).
/// Barvy terminálu – čte aktuální profil terminálu (ThemeStore.terminal).
enum TabbyTheme {
    static var foreground: String { ThemeStore.terminal.foreground }
    static var background: String { ThemeStore.terminal.background }
    static var cursor: String { ThemeStore.terminal.cursor }
    static var ansi: [String] { ThemeStore.terminal.ansi }

    static func nsColor(_ hex: String) -> NSColor {
        guard let c = RGBColor(hex: hex) else { return .gray }
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    @MainActor
    static func apply(to tv: TerminalView) {
        let palette = ansi.compactMap(RGBColor.init(hex:)).map {
            SwiftTerm.Color(red8: UInt16($0.r), green8: UInt16($0.g), blue8: UInt16($0.b))
        }
        tv.installColors(palette)
        tv.nativeForegroundColor = nsColor(foreground)
        tv.nativeBackgroundColor = nsColor(background)
        tv.caretColor = nsColor(cursor)
        tv.caretTextColor = nsColor(ThemeStore.terminal.cursorText)
        tv.selectedTextBackgroundColor = nsColor(ThemeStore.terminal.selectionBackground)
    }
}
