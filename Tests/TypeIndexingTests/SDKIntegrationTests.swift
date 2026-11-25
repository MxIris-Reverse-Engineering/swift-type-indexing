#if os(macOS)

import Foundation
import Testing
@testable import TypeIndexing

/// Against the SDKs of this Mac's active developer directory. Off by default
/// — the results depend on which SDKs are installed — and run by hand:
///
/// ```bash
/// TYPE_INDEXING_SDK_TESTS=1 swift test --filter SDKIntegrationTests
/// ```
///
/// Only API notes are read (`moduleFilter` selects no module), so no
/// sourcekitd work runs and nothing is written outside a temporary directory.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TYPE_INDEXING_SDK_TESTS"] == "1"))
struct SDKIntegrationTests {
    private static func indexedDatabase(for platform: SDKPlatform) async throws -> TypeDatabase {
        let cacheDirectoryURL = FileManager.default.temporaryDirectory
            .appending(component: "SDKIntegrationTests-\(UUID().uuidString)")
        let typeDatabase = TypeDatabase(platform: platform, cacheDirectory: cacheDirectoryURL)
        try await typeDatabase.index(dependencies: [], moduleFilter: { _ in false })
        try? FileManager.default.removeItem(at: cacheDirectoryURL)
        return typeDatabase
    }

    /// The case that started the package: Mac Catalyst UIKit's bridged
    /// configuration state, `SwiftPrivate: true` in UIKit's API notes.
    @Test
    func macCatalystUIKitSwiftPrivateClassResolves() async throws {
        let typeDatabase = try await Self.indexedDatabase(for: .macCatalyst)
        #expect(await typeDatabase.moduleName(forTypeName: "UICellConfigurationState") == "UIKit")
        #expect(await typeDatabase.swiftName(forCName: "UICellConfigurationState", category: .objcClass) == "__UICellConfigurationState")
    }

    /// PencilKit's drawing, `SwiftName: PKDrawingReference` in its API notes.
    @Test
    func macOSPencilKitSwiftNameResolves() async throws {
        let typeDatabase = try await Self.indexedDatabase(for: .macOS)
        #expect(await typeDatabase.moduleName(forTypeName: "PKDrawing") == "PencilKit")
        #expect(await typeDatabase.swiftName(forCName: "PKDrawing", category: .objcClass) == "PKDrawingReference")
    }

    /// The annotations an Objective-C header printer marks: the class-level
    /// `SwiftName` of PencilKit's drawing, and the `SwiftPrivate` of Mac
    /// Catalyst UIKit's configuration state.
    @Test
    func objcSwiftImportAnnotationsComeFromTheSDK() async throws {
        let macOSDatabase = try await Self.indexedDatabase(for: .macOS)
        #expect(await macOSDatabase.swiftImportAnnotations(forObjCClassNamed: "PKDrawing")?.declaration?.swiftName == "PKDrawingReference")
        let macCatalystDatabase = try await Self.indexedDatabase(for: .macCatalyst)
        #expect(await macCatalystDatabase.swiftImportAnnotations(forObjCClassNamed: "UICellConfigurationState")?.declaration?.isSwiftPrivate == true)
    }

    /// Module interfaces through sourcekitd, for a type no API notes file
    /// lists. Slow — the first generation of UIKit's interface takes tens of
    /// seconds — so it needs `TYPE_INDEXING_SOURCEKIT_TESTS=1` as well.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPE_INDEXING_SOURCEKIT_TESTS"] == "1"))
    func macCatalystModuleInterfaceAttributesUIKitTypes() async throws {
        let cacheDirectoryURL = FileManager.default.temporaryDirectory
            .appending(component: "SDKIntegrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectoryURL) }
        let typeDatabase = TypeDatabase(platform: .macCatalyst, cacheDirectory: cacheDirectoryURL)
        try await typeDatabase.index(dependencies: [], moduleFilter: { $0 == "UIKit" })
        // UIStackView is listed in no API notes file: only the interface names it.
        #expect(await typeDatabase.moduleName(forTypeName: "UIStackView") == "UIKit")
    }

    @Test
    func macOSDoesNotSeeMacCatalystUIKit() async throws {
        let typeDatabase = try await Self.indexedDatabase(for: .macOS)
        #expect(await typeDatabase.swiftName(forCName: "UICellConfigurationState", category: .objcClass) == nil)
    }

    /// CoreFoundation declares `CGFloat` under
    /// `@_originallyDefinedIn(module: "CoreGraphics", macOS 10.0)`.
    @Test
    func cgFloatMovedFromCoreGraphicsToCoreFoundation() async throws {
        let typeDatabase = try await Self.indexedDatabase(for: .macOS)
        let sdkVersion = OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "CGFloat", originallyDefinedIn: "CoreGraphics", builtAgainst: sdkVersion) == "CoreFoundation")
    }

    /// SwiftUICore took `View` over from SwiftUI in macOS 15.
    @Test
    func swiftUIViewMovedToSwiftUICoreInMacOS15() async throws {
        let typeDatabase = try await Self.indexedDatabase(for: .macOS)
        let macOS15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        let macOS14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 0)
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "View", originallyDefinedIn: "SwiftUI", builtAgainst: macOS15) == "SwiftUICore")
        #expect(await typeDatabase.declaringModuleName(ofMovedTypeNamed: "View", originallyDefinedIn: "SwiftUI", builtAgainst: macOS14) == nil)
    }
}

#endif
