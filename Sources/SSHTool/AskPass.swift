import Foundation

enum AskPass {
    static func run(sessionID: String, prompt: String) -> Never {
        let p = prompt.lowercased()
        // Odpovídáme jen na dotaz na heslo/passphrase. Cokoliv jiného (yes/no apod.) odmítneme.
        guard p.contains("password") || p.contains("passphrase") else {
            FileHandle.standardError.write(Data("sshtool: neznámý askpass dotaz: \(prompt)\n".utf8))
            exit(1)
        }
        // Session s ochranou: před vydáním hesla Touch ID / heslo macOS.
        // Chrání i proti tomu, že binárku v režimu askpass spustí jiný program – uvidíš nečekaný dialog a zrušíš ho.
        if KeychainStore.requiresAuth(for: sessionID) {
            let target = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard UserAuth.authenticate(reason: "použít uložené heslo SSHTool (\(target))") else {
                FileHandle.standardError.write(Data("sshtool: ověření Touch ID / heslem Macu zrušeno nebo selhalo\n".utf8))
                exit(1)
            }
        }
        guard let secret = KeychainStore.password(for: sessionID) else { exit(1) }
        FileHandle.standardOutput.write(Data((secret + "\n").utf8))
        exit(0)
    }
}
