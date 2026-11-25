#if os(macOS)

import Foundation
import Testing
@testable import TypeIndexing

/// `TypeDatabase.declaringModuleName(ofMovedTypeNamed:originallyDefinedIn:builtAgainst:)`
/// over moves registered directly — no SDK scan.
@Suite
struct TypeDatabaseMovedTypeTests {
    private static func version(_ text: String) -> PlatformVersion {
        PlatformVersion(text)!
    }

    private static func sdkVersion(_ majorVersion: Int, _ minorVersion: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: majorVersion, minorVersion: minorVersion, patchVersion: 0)
    }

    private static let movedView = MovedTypeDeclaration(
        typeName: "View",
        originalModuleName: "SwiftUI",
        declaringModuleName: "SwiftUICore",
        movedVersionsByPlatformName: ["macOS": version("15.0"), "iOS": version("18.0"), "tvOS": version("18.0"), "watchOS": version("11.0")]
    )

    private static func database(for platform: SDKPlatform, registering movedTypeDeclarations: [MovedTypeDeclaration] = [movedView]) async -> TypeDatabase {
        let typeDatabase = TypeDatabase(platform: platform)
        await typeDatabase.register(movedTypeDeclarations: movedTypeDeclarations)
        return typeDatabase
    }

    @Test
    func answersTheDeclaringModuleWhenTheSDKIsNotOlderThanTheMove() async {
        let typeDatabase = await Self.database(for: .macOS)
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "View", originallyDefinedIn: "SwiftUI", builtAgainst: Self.sdkVersion(15)) == "SwiftUICore")
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "View", originallyDefinedIn: "SwiftUI", builtAgainst: Self.sdkVersion(27, 2)) == "SwiftUICore")
    }

    /// The macOS 14 SwiftUI declares `View` itself; its interface keeps it
    /// there.
    @Test
    func answersNothingForAnSDKOlderThanTheMove() async {
        let typeDatabase = await Self.database(for: .macOS)
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "View", originallyDefinedIn: "SwiftUI", builtAgainst: Self.sdkVersion(14, 6)) == nil)
    }

    @Test
    func answersNothingForATypeThatNeverMoved() async {
        let typeDatabase = await Self.database(for: .macOS)
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "Text", originallyDefinedIn: "SwiftUI", builtAgainst: Self.sdkVersion(27)) == nil)
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "View", originallyDefinedIn: "AppKit", builtAgainst: Self.sdkVersion(27)) == nil)
    }

    @Test
    func answersNothingBeforeIndexing() async {
        let typeDatabase = TypeDatabase(platform: .macOS)
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "View", originallyDefinedIn: "SwiftUI", builtAgainst: Self.sdkVersion(27)) == nil)
    }

    /// An attribute naming no version for the platform is inactive there:
    /// the mangling names the declaring module already.
    @Test
    func answersNothingOnAPlatformTheAttributeDoesNotName() async {
        let typeDatabase = await Self.database(for: .driverKit)
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "View", originallyDefinedIn: "SwiftUI", builtAgainst: Self.sdkVersion(27)) == nil)
    }

    /// Mac Catalyst takes its own attribute when there is one, else iOS's,
    /// whose version numbers it shares.
    @Test
    func macCatalystFallsBackToTheIOSVersion() async {
        let typeDatabase = await Self.database(for: .macCatalyst, registering: [
            Self.movedView,
            MovedTypeDeclaration(
                typeName: "CGFloat",
                originalModuleName: "CoreGraphics",
                declaringModuleName: "CoreFoundation",
                movedVersionsByPlatformName: ["iOS": Self.version("2.0"), "macCatalyst": Self.version("13.0")]
            ),
        ])
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "View", originallyDefinedIn: "SwiftUI", builtAgainst: Self.sdkVersion(18)) == "SwiftUICore")
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "View", originallyDefinedIn: "SwiftUI", builtAgainst: Self.sdkVersion(17, 5)) == nil)
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "CGFloat", originallyDefinedIn: "CoreGraphics", builtAgainst: Self.sdkVersion(12)) == nil)
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "CGFloat", originallyDefinedIn: "CoreGraphics", builtAgainst: Self.sdkVersion(13)) == "CoreFoundation")
    }

    /// visionOS takes an iOS attribute as the compiler does, mapping its
    /// version: iOS 18 is visionOS 2.
    @Test
    func visionOSMapsTheIOSVersion() async {
        let typeDatabase = await Self.database(for: .visionOS)
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "View", originallyDefinedIn: "SwiftUI", builtAgainst: Self.sdkVersion(2)) == "SwiftUICore")
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "View", originallyDefinedIn: "SwiftUI", builtAgainst: Self.sdkVersion(1, 2)) == nil)
        #expect(MovedTypeDeclaration.visionOSVersion(forIOSVersion: Self.version("18.2")) == Self.version("2.2"))
        #expect(MovedTypeDeclaration.visionOSVersion(forIOSVersion: Self.version("26.0")) == Self.version("26.0"))
        #expect(MovedTypeDeclaration.visionOSVersion(forIOSVersion: Self.version("2.0")) == PlatformVersion(components: []))
    }

    @Test
    func firstDiscoveredModuleWinsATiedKey() async {
        let typeDatabase = await Self.database(for: .macOS, registering: [
            Self.movedView,
            MovedTypeDeclaration(
                typeName: "View",
                originalModuleName: "SwiftUI",
                declaringModuleName: "SomewhereElse",
                movedVersionsByPlatformName: ["macOS": Self.version("10.0")]
            ),
        ])
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "View", originallyDefinedIn: "SwiftUI", builtAgainst: Self.sdkVersion(27)) == "SwiftUICore")
    }
}

#endif
