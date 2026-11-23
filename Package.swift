// swift-tools-version: 6.3

@preconcurrency import PackageDescription
import Foundation

func envEnable(_ key: String, default defaultValue: Bool = false) -> Bool {
    let value = Context.environment[key]
    guard let value else {
        return defaultValue
    }
    if value == "1" {
        return true
    } else if value == "0" {
        return false
    } else {
        return defaultValue
    }
}

let usingLocalDependencies = envEnable("USING_LOCAL_DEPENDENCIES")

extension Package.Dependency {
    enum LocalSearchPath {
        case package(path: String, isRelative: Bool, isEnabled: Bool = usingLocalDependencies, traits: Set<PackageDescription.Package.Dependency.Trait> = [.defaults])
    }

    /// The first enabled local checkout that exists, else `remote`. A copy of
    /// this package that SwiftPM or Xcode cloned as someone's dependency always
    /// takes `remote`.
    static func package(local localSearchPaths: LocalSearchPath..., remote: Package.Dependency) -> Package.Dependency {
        let currentFilePath = #filePath
        let isClonedDependency = currentFilePath.contains("/checkouts/") ||
            currentFilePath.contains("/SourcePackages/") ||
            currentFilePath.contains("/.build/")

        if isClonedDependency {
            return remote
        }
        for local in localSearchPaths {
            switch local {
            case .package(let path, let isRelative, let isEnabled, let traits):
                guard isEnabled else { continue }
                let url = if isRelative {
                    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: currentFilePath))
                } else {
                    URL(fileURLWithPath: path)
                }

                if FileManager.default.fileExists(atPath: url.path) {
                    return .package(path: url.path, traits: traits)
                }
            }
        }
        return remote
    }
}

// Every source file is `#if os(macOS)`: the index runs the SDK's own tools
// (`xcrun`, sourcekitd). The platforms below are the ones the packages that
// depend on this one support; declaring only macOS here would make SwiftPM
// reject them, so they depend on it with a macOS-only condition instead.
let package = Package(
    name: "swift-type-indexing",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6), .visionOS(.v1)],
    products: [
        .library(name: "TypeIndexing", targets: ["TypeIndexing"]),
    ],
    dependencies: [
        // Logging macros (`@Loggable`, `#log`).
        .package(url: "https://github.com/Mx-Iris/FrameworkToolbox", from: "0.17.0"),
        // Loads sourcekitd from the active developer directory to generate
        // module interfaces.
        .package(url: "https://github.com/Mx-Iris/SourceKitD", from: "0.1.0"),
        // Decodes `.apinotes` files. 0.3.0 is the first release whose
        // Objective-C classes and protocols expose their methods and
        // properties, which the Swift import annotations read.
        .package(
            local: .package(path: "../../../Fork/Library/swift-apinotes", isRelative: true),
            remote: .package(url: "https://github.com/MxIris-DeveloperTool/swift-apinotes", from: "0.3.0")
        ),
    ],
    targets: [
        .target(
            name: "TypeIndexing",
            dependencies: [
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
                .product(name: "SourceKitD", package: "SourceKitD", condition: .when(platforms: [.macOS])),
                .product(name: "APINotes", package: "swift-apinotes", condition: .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "TypeIndexingTests",
            dependencies: [
                "TypeIndexing",
            ]
        ),
    ]
)

// The upcoming features the MachO packages adopt (MachOSwiftSection's
// proposal swift6-mode-and-upcoming-features).
let upcomingFeatureSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + upcomingFeatureSettings
}
