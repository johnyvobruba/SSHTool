// Podepíše soubor aktualizace klíčem Ed25519 (base64 raw klíč v proměnné UPDATE_SIGNING_KEY).
//   UPDATE_SIGNING_KEY=... swift scripts/sign-update.swift SSHTool-0.23.0.zip   → SSHTool-0.23.0.zip.sig
import Foundation
import CryptoKit

guard CommandLine.arguments.count == 2 else { print("použití: sign-update.swift <soubor>"); exit(2) }
let path = CommandLine.arguments[1]
guard let b64 = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      let raw = Data(base64Encoded: b64),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    print("Chybí nebo je neplatný UPDATE_SIGNING_KEY"); exit(1)
}
let data = try! Data(contentsOf: URL(fileURLWithPath: path))
let sig = try! key.signature(for: data)
// kontrola proti veřejnému klíči v repozitáři (chrání před podpisem špatným klíčem)
if let pubText = try? String(contentsOfFile: "update-public-key.txt", encoding: .utf8),
   let pubRaw = Data(base64Encoded: pubText.trimmingCharacters(in: .whitespacesAndNewlines)),
   let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubRaw),
   !pub.isValidSignature(sig, for: data) {
    print("Podpis neodpovídá update-public-key.txt – špatný klíč v secretu?"); exit(1)
}
try! (sig.base64EncodedString() + "\n").write(toFile: path + ".sig", atomically: true, encoding: .utf8)
print("✔ \(path).sig")
