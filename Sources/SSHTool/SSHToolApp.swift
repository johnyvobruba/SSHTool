import SwiftUI

// Pozor: bez @main – vstupní bod je main.swift (kvůli askpass režimu).
struct SSHToolApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var tabs = TabManager()
    @StateObject private var serial = SerialMonitor()

    var body: some Scene {
        // Jedno hlavní okno jako v Tabby: vlevo session, vpravo záložky s terminály.
        Window("SSHTool", id: "main") {
            MainView()
                .environmentObject(store)
                .environmentObject(tabs)
                .environmentObject(serial)
                .tint(UI.accent)
                .preferredColorScheme(store.isDarkUI ? .dark : .light)
                .id(store.themeKey)               // nový profil = překreslit okno; SSH relace běží dál
        }
        .windowStyle(.hiddenTitleBar)          // bez titulkové lišty – vše je v záložkách a stavovém řádku
        .commands {
            // ⌘W má zavírat záložku, ne celé okno (okno zavřeš červeným tlačítkem).
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("O aplikaci SSHTool") { AppCredits.showAbout() }
                Button("Zkontrolovat aktualizace…") { Updater.shared.check(interactive: true) }
            }
            // View → skrýt/zobrazit levý panel (víc místa pro terminál při debugu)
            CommandGroup(after: .sidebar) {
                Button("Režim soustředění") { tabs.toggleFocus() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .sidebar) {
                Button("Skrýt / zobrazit seznam session") { tabs.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Divider()
                Button("Zvětšit písmo") { store.changeFontSize(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zmenšit písmo") { store.changeFontSize(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Výchozí velikost písma") { store.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Nová záložka…") { tabs.showPicker = true }
                    .keyboardShortcut("t")
                Button("Příkazová paleta / hledat server") { tabs.showPicker = true }
                    .keyboardShortcut("k")
                Button("Rychlé připojení (user@host:port)…") { tabs.showQuickConnect = true }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Lokální terminál") { tabs.openLocal() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("SFTP k aktivní session") { tabs.sftpForSelected() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Web (https) aktivní session") {
                    if let t = tabs.selected, t.kind != .local { WebOpener.open(t.session) }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Importovat session…") { store.importSessionsPanel() }
                Button("Exportovat servery bez hesel…") { store.exportSessionsPanel() }
                Button("Uložit vzor JSON se servery…") { store.saveSessionsTemplatePanel() }
            }
            // ⌘F / ⌘G – hledání ve výstupu aktivního terminálu
            CommandGroup(replacing: .textEditing) {
                Button("Hledat ve výstupu…") { tabs.selected?.view.showFind() }
                    .keyboardShortcut("f")
                Button("Najít další") { tabs.selected?.view.findAgain(forward: true) }
                    .keyboardShortcut("g")
                Button("Najít předchozí") { tabs.selected?.view.findAgain(forward: false) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandMenu("Terminál") {
                Button("Broadcast vstupu do více relací…") { tabs.toggleBroadcast() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Soubory serveru (SFTP)") { tabs.toggleFiles() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(tabs.selected == nil)
                Button("Zachytávání paketů (tcpdump / fw monitor)…") { tabs.showCapture = true }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(tabs.selected == nil)
                Button("Poslat Break (sériová konzole)") { tabs.sendBreakToSelected() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Divider()
                Button("Vyčistit obrazovku") { tabs.clearSelected() }
                    .keyboardShortcut("l")
                Button("Hledat v historii (Ctrl+R) / znovu připojit odpojené") { tabs.smartR() }
                    .keyboardShortcut("r")
            }
            CommandMenu("Záložky") {
                Button("Zavřít záložku") { tabs.closeSelected() }
                    .keyboardShortcut("w")
                Button("Znovu připojit") { tabs.reconnectSelected() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Zapnout / vypnout logování") { tabs.toggleLoggingSelected() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Duplikovat záložku") { tabs.duplicateSelected() }
                Divider()
                Button("Přidat panel – vedle") { tabs.split(.vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Přidat panel – pod") { tabs.split(.horizontal) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Další panel") { tabs.focusPane(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Předchozí panel") { tabs.focusPane(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Otočit pořadí panelů") { tabs.swapPanes() }
                Button("Zrušit rozdělení") { tabs.unsplit() }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                Divider()
                Button("Další záložka") { tabs.cycle(1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Předchozí záložka") { tabs.cycle(-1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Button("Další záložka ") { tabs.cycle(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Předchozí záložka ") { tabs.cycle(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Posunout vlevo") { tabs.moveSelected(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                Button("Posunout vpravo") { tabs.moveSelected(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                Divider()
                ForEach(1..<10) { i in
                    Button("Záložka \(i)") { tabs.select(index: i - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(i))), modifiers: .command)
                }
            }
        }

        // ⌘, – nastavení s postranní navigací
        Settings {
            SettingsRootView()
            .environmentObject(store)
            .preferredColorScheme(store.isDarkUI ? .dark : .light)
        }
    }
}
