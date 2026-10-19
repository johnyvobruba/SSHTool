// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SSHTool",
    platforms: [.macOS(.v13)],
    dependencies: [
        // API SwiftTermu se mezi verzemi výrazně mění (1.99 = přepsaná I/O vrstva) → pevná verze.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.0"),
    ],
    targets: [
        .executableTarget(
            name: "SSHTool",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/SSHTool"
        ),
    ]
)
