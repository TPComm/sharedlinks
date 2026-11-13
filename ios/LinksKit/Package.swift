// swift-tools-version: 6.0
import PackageDescription

// Code shared by the app, the Share Extension and the widgets: API client, models,
// the shared session (keychain, via the App Group) and the on-disk inbox cache.
let package = Package(
    name: "LinksKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "LinksKit", targets: ["LinksKit"])],
    targets: [
        .target(name: "LinksKit"),
        .testTarget(name: "LinksKitTests", dependencies: ["LinksKit"]),
    ]
)
