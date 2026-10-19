import SwiftUI
import AppKit

/// Barevný profil = UI aplikace + terminál (ANSI). Význam stavových barev je ve všech profilech stejný:
/// zelená připojeno, žlutá připojování, šedá bez relace, červená chyba – mění se jen odstín.
struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let note: String
    let isDark: Bool

    // Application UI
    let appBackground, sidebarBackground, toolbarBackground: String
    let tabInactiveBackground, tabActiveBackground: String
    let itemSelectedBackground, itemHoverBackground, borderColor: String
    let textPrimary, textSecondary, textTertiary, accentColor: String
    // Connection status
    let statusConnected, statusConnecting, statusError: String
    // Terminal
    let foreground, background, cursor, cursorText, selectionBackground: String
    let ansiNormal: [String]   // black red green yellow blue magenta cyan white
    let ansiBright: [String]

    var statusDisconnected: String { textTertiary }
    var ansi: [String] { ansiNormal + ansiBright }

    static func == (a: Theme, b: Theme) -> Bool { a.id == b.id }
}

extension Theme {
    static let midnight = Theme(
        id: "midnight", name: "Midnight Graphite", note: "Výchozí · neutrální, profesionální", isDark: true,
        appBackground: "#181A20", sidebarBackground: "#20232B", toolbarBackground: "#1D2028",
        tabInactiveBackground: "#252933", tabActiveBackground: "#303747",
        itemSelectedBackground: "#343E52", itemHoverBackground: "#2B303C", borderColor: "#363C48",
        textPrimary: "#E6E9EF", textSecondary: "#929AAA", textTertiary: "#5F6778", accentColor: "#7299FF",
        statusConnected: "#4BC995", statusConnecting: "#E7B765", statusError: "#E5747A",
        foreground: "#D9DDE5", background: "#14161B", cursor: "#7299FF", cursorText: "#14161B",
        selectionBackground: "#343E52",
        ansiNormal: ["#252933", "#E5747A", "#4BC995", "#E7B765", "#7299FF", "#C69AE8", "#76C7D9", "#D5D9E2"],
        ansiBright: ["#3A4150", "#F08C91", "#6FD9AB", "#F0CA88", "#94B2FF", "#D6B3F0", "#98D8E6", "#F2F4F8"])

    static let tokyo = Theme(
        id: "tokyo", name: "Tokyo Night", note: "Modrofialový · pro vývojáře", isDark: true,
        appBackground: "#1A1B26", sidebarBackground: "#1F2335", toolbarBackground: "#1B1E2B",
        tabInactiveBackground: "#24283B", tabActiveBackground: "#303653",
        itemSelectedBackground: "#343B58", itemHoverBackground: "#292E42", borderColor: "#3B4261",
        textPrimary: "#C0CAF5", textSecondary: "#8992B3", textTertiary: "#565F89", accentColor: "#7AA2F7",
        statusConnected: "#9ECE6A", statusConnecting: "#E0AF68", statusError: "#F7768E",
        foreground: "#C0CAF5", background: "#16161E", cursor: "#7AA2F7", cursorText: "#16161E",
        selectionBackground: "#343B58",
        ansiNormal: ["#15161E", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5"],
        ansiBright: ["#414868", "#FF8FA3", "#B5E08A", "#EBC48C", "#9BB8FA", "#CDB2FA", "#A2DCFF", "#D5DCF9"])

    static let nord = Theme(
        id: "nord", name: "Nord Frost", note: "Studený, jemné kontrasty · dlouhá práce", isDark: true,
        appBackground: "#2E3440", sidebarBackground: "#353C4A", toolbarBackground: "#303744",
        tabInactiveBackground: "#3B4252", tabActiveBackground: "#434D60",
        itemSelectedBackground: "#455468", itemHoverBackground: "#3D4656", borderColor: "#4C566A",
        textPrimary: "#ECEFF4", textSecondary: "#A7B2C3", textTertiary: "#6B778D", accentColor: "#88C0D0",
        statusConnected: "#A3BE8C", statusConnecting: "#EBCB8B", statusError: "#BF616A",
        foreground: "#D8DEE9", background: "#292F3B", cursor: "#88C0D0", cursorText: "#2E3440",
        selectionBackground: "#455468",
        ansiNormal: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0"],
        ansiBright: ["#4C566A", "#D57780", "#B6CFA2", "#F0D8A8", "#93B0CF", "#C4A3BE", "#8FBCBB", "#ECEFF4"])

    static let catppuccin = Theme(
        id: "catppuccin", name: "Catppuccin Mocha", note: "Pastelový, měkčí kontrasty", isDark: true,
        appBackground: "#1E1E2E", sidebarBackground: "#242438", toolbarBackground: "#202033",
        tabInactiveBackground: "#313244", tabActiveBackground: "#3B3D55",
        itemSelectedBackground: "#41435E", itemHoverBackground: "#35364B", borderColor: "#45475A",
        textPrimary: "#CDD6F4", textSecondary: "#A6ADC8", textTertiary: "#6C7086", accentColor: "#B4BEFE",
        statusConnected: "#A6E3A1", statusConnecting: "#F9E2AF", statusError: "#F38BA8",
        foreground: "#CDD6F4", background: "#181825", cursor: "#F5E0DC", cursorText: "#1E1E2E",
        selectionBackground: "#41435E",
        ansiNormal: ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#CBA6F7", "#94E2D5", "#BAC2DE"],
        ansiBright: ["#585B70", "#F5A3BA", "#BCEBB8", "#FBEAC3", "#A6C6FB", "#F5C2E7", "#ADE9DE", "#CDD6F4"])

    static let emerald = Theme(
        id: "emerald", name: "Emerald Terminal", note: "Síťová konzole · zelenomodrý akcent", isDark: true,
        appBackground: "#151D1C", sidebarBackground: "#1D2927", toolbarBackground: "#192320",
        tabInactiveBackground: "#24312D", tabActiveBackground: "#2B403A",
        itemSelectedBackground: "#305047", itemHoverBackground: "#283A34", borderColor: "#375047",
        textPrimary: "#E0EEE8", textSecondary: "#93AEA3", textTertiary: "#5B7A6E", accentColor: "#55D6A0",
        statusConnected: "#6EE7A8", statusConnecting: "#E8BC75", statusError: "#F08080",
        foreground: "#D7E8E0", background: "#101816", cursor: "#55D6A0", cursorText: "#101816",
        selectionBackground: "#305047",
        ansiNormal: ["#24312D", "#F08080", "#6EE7A8", "#E8BC75", "#70A9C4", "#C39BD3", "#69D2C2", "#D4E8DE"],
        ansiBright: ["#3A4E47", "#F59C9C", "#8FF0BE", "#F0CC92", "#8FC0D6", "#D3B5E0", "#8FE0D3", "#EEF7F2"])

    static let arctic = Theme(
        id: "arctic", name: "Arctic Light", note: "Světlý · denní režim", isDark: false,
        appBackground: "#F3F5F8", sidebarBackground: "#E9EDF3", toolbarBackground: "#EDF0F5",
        tabInactiveBackground: "#E2E7EF", tabActiveBackground: "#FFFFFF",
        itemSelectedBackground: "#D8E5FA", itemHoverBackground: "#DFE6EF", borderColor: "#CAD3DF",
        textPrimary: "#202938", textSecondary: "#526176", textTertiary: "#69788D", accentColor: "#356AC3",
        statusConnected: "#18794E", statusConnecting: "#A96816", statusError: "#C43D4B",
        foreground: "#202938", background: "#FFFFFF", cursor: "#356AC3", cursorText: "#FFFFFF",
        selectionBackground: "#D8E5FA",
        ansiNormal: ["#303846", "#C43D4B", "#18794E", "#A96816", "#356AC3", "#8C4DB5", "#087F8C", "#465365"],
        ansiBright: ["#6B7788", "#D9535F", "#1F9461", "#C07B1E", "#4A82D9", "#A365CC", "#0E98A7", "#202938"])

    static let all: [Theme] = [.midnight, .tokyo, .nord, .catppuccin, .emerald, .arctic]

    static func byID(_ id: String) -> Theme { all.first { $0.id == id } ?? .midnight }
}

/// Centrální stav motivu. Čtou ho všechny komponenty (UI.*, TabbyTheme.*); nastavuje AppStore.
enum ThemeStore {
    nonisolated(unsafe) static var ui: Theme = .midnight
    nonisolated(unsafe) static var terminal: Theme = .midnight
    static let changed = Notification.Name("SSHToolThemeChanged")

    /// Systémový vzhled macOS (Tmavý/Světlý, platí i pro „Automaticky“).
    static var systemIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }

    static func resolve(_ s: AppSettings) -> (ui: Theme, terminal: Theme) {
        let chosen = Theme.byID(s.themeID)
        let dark = chosen.isDark ? chosen : .midnight
        let ui: Theme
        switch s.appearance {
        case "light": ui = .arctic
        case "system": ui = systemIsDark ? dark : (chosen.isDark ? .arctic : chosen)
        default: ui = chosen.isDark ? chosen : dark
        }
        let term = s.terminalFollowsApp ? ui : Theme.byID(s.terminalThemeID)
        return (ui, term)
    }
}

// Okno nastavení: viz SettingsUI.swift
