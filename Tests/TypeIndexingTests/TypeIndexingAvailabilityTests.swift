#if os(macOS)

import Foundation
import Testing
@testable import TypeIndexing

/// Whether a Mac can index a platform: it needs a developer directory with
/// the platform's SDK; sourcekitd is optional.
@Suite
struct TypeIndexingAvailabilityTests {
    private struct LookupFailed: Error {}

    private static let commandLineToolsDirectory = "/Library/Developer/CommandLineTools"
    private static let sourceKitPath = commandLineToolsDirectory + "/usr/lib/sourcekitd.framework/Versions/A/sourcekitd"
    private static let sdkSettings = SDKSettings(sdkPath: commandLineToolsDirectory + "/SDKs/MacOSX.sdk", version: "27.2", productBuildVersion: "27C5")

    @Test
    func availabilityReportsMissingDeveloperDirectory() {
        let availability = TypeIndexingAvailability.availability(
            for: .macOS,
            developerDirectory: { throw LookupFailed() },
            sdkSettings: { _ in Self.sdkSettings },
            fileExists: { _ in true }
        )
        #expect(!availability.isAvailable)
        #expect(availability.unavailabilityReason == .noDeveloperDirectory)
        #expect(availability.sdkSettings == nil)
    }

    /// The Command Line Tools carry the macOS SDK only: an iOS file cannot be
    /// indexed there.
    @Test
    func availabilityReportsMissingSDK() {
        let availability = TypeIndexingAvailability.availability(
            for: .iOS,
            developerDirectory: { Self.commandLineToolsDirectory },
            sdkSettings: { _ in throw LookupFailed() },
            fileExists: { $0 == Self.sourceKitPath }
        )
        #expect(!availability.isAvailable)
        #expect(availability.unavailabilityReason == .sdkNotInstalled(.iOS))
    }

    @Test
    func sdkWithSourceKitIsFullyAvailable() {
        let availability = TypeIndexingAvailability.availability(
            for: .macOS,
            developerDirectory: { Self.commandLineToolsDirectory },
            sdkSettings: { _ in Self.sdkSettings },
            fileExists: { $0 == Self.sourceKitPath }
        )
        #expect(availability.isAvailable)
        #expect(availability.sdkSettings == Self.sdkSettings)
        #expect(availability.sourceKitPath == Self.sourceKitPath)
    }

    /// Without sourcekitd the platform is still available: API notes and
    /// runtime metadata resolve names, only module interfaces are skipped.
    @Test
    func sdkWithoutSourceKitIsAvailableWithoutModuleInterfaces() {
        let availability = TypeIndexingAvailability.availability(
            for: .macOS,
            developerDirectory: { Self.commandLineToolsDirectory },
            sdkSettings: { _ in Self.sdkSettings },
            fileExists: { _ in false }
        )
        #expect(availability.isAvailable)
        #expect(availability.sourceKitPath == nil)
    }
}

#endif
