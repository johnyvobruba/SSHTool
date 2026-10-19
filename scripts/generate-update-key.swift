// Vygeneruje klíčový pár Ed25519 pro podpis aktualizací SSHTool.
//   swift scripts/generate-update-key.swift
// → veřejný klíč do update-public-key.txt (patří do repozitáře, aplikace jím ověřuje stažené aktualizace)
// → soukromý klíč do ~/.sshtool-update-signing-key (práva 600, NIKDY do repozitáře)
//   nahraj ho jako GitHub secret:  gh secret set UPDATE_SIGNING_KEY < ~/.sshtool-update-signing-key
import Foundation
import CryptoKit

let privURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sshtool-update-signing-key")
if FileManager.default.fileExists(atPath: privURL.path) {
    print("Soukromý klíč už existuje: \(privURL.path) – nepřepisuji (smaž ho ručně, pokud opravdu chceš nový pár).")
    exit(1)
}
let key = Curve25519.Signing.PrivateKey()
let priv = key.rawRepresentation.base64EncodedString()
let pub = key.publicKey.rawRepresentation.base64EncodedString()
FileManager.default.createFile(atPath: privURL.path, contents: Data(priv.utf8), attributes: [.posixPermissions: 0o600])
try! (pub + "\n").write(toFile: "update-public-key.txt", atomically: true, encoding: .utf8)
print("✔ Veřejný klíč:  update-public-key.txt  (\(pub))")
print("✔ Soukromý klíč: \(privURL.path)  (práva 600)")
print("Dál:  gh secret set UPDATE_SIGNING_KEY < \(privURL.path)")
