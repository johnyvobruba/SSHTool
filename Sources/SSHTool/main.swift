import Foundation

// Když nás ssh spustí jako SSH_ASKPASS, jen vrátíme heslo z Keychainu a skončíme (bez UI).
if let sessionID = ProcessInfo.processInfo.environment["SSHTOOL_SESSION_ID"] {
    AskPass.run(sessionID: sessionID,
                prompt: CommandLine.arguments.dropFirst().joined(separator: " "))
}

// Sériová konzole: tatáž binárka jako most mezi terminálem (PTY) a portem /dev/cu.*.
let launchEnv = ProcessInfo.processInfo.environment
if let port = launchEnv["SSHTOOL_SERIAL_PORT"] {
    SerialBridge.run(path: port,
                     baud: Int(launchEnv["SSHTOOL_SERIAL_BAUD"] ?? "") ?? SerialConfig.defaultBaud,
                     rtscts: launchEnv["SSHTOOL_SERIAL_FLOW"] == "rtscts")
}

// Zápis do roury, kterou druhá strana zavřela (např. zavřený Wireshark), nesmí aplikaci shodit (SIGPIPE).
signal(SIGPIPE, SIG_IGN)

SSHToolApp.main()
