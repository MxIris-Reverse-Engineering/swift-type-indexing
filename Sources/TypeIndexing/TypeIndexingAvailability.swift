#if os(macOS)

import Foundation

/// Whether this Mac can index an SDK platform, and why not.
///
/// Indexing needs a developer directory holding the platform's SDK: an Xcode
/// for any platform, or the Command Line Tools for macOS and Mac Catalyst
/// (whose API notes live in the macOS SDK's `iOSSupport`). sourcekitd is
/// optional — without it ``TypeDatabase`` still resolves names from API notes
/// and runtime metadata, and only skips module interfaces.
@available(macOS 13.0, *)
public struct TypeIndexingAvailability: Sendable, Hashable {
    public enum UnavailabilityReason: Sendable, Hashable {
        /// No developer directory is selected (`xcode-select -p` fails).
        case noDeveloperDirectory
        /// The developer directory has no SDK for the platform, as the
        /// Command Line Tools have none for iOS.
        case sdkNotInstalled(SDKPlatform)
    }

    /// The platform's SDK, when it is installed.
    public let sdkSettings: SDKSettings?

    /// sourcekitd, when the developer directory has it.
    public let sourceKitPath: String?

    /// Why the platform cannot be indexed, or `nil` when it can.
    public let unavailabilityReason: UnavailabilityReason?

    public var isAvailable: Bool {
        unavailabilityReason == nil
    }

    /// Looks the platform up in the active developer directory. Runs
    /// `xcode-select` and `xcrun`, so it takes tens of milliseconds; callers
    /// keep the result.
    public static func availability(for platform: SDKPlatform) -> TypeIndexingAvailability {
        availability(
            for: platform,
            developerDirectory: { try Subprocess.activeDeveloperDirectory() },
            sdkSettings: { try $0.sdkSettings() },
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    /// Test seam: the three lookups the public form makes.
    static func availability(
        for platform: SDKPlatform,
        developerDirectory: () throws -> String,
        sdkSettings: (SDKPlatform) throws -> SDKSettings,
        fileExists: (String) -> Bool
    ) -> TypeIndexingAvailability {
        guard let developerDirectoryPath = try? developerDirectory() else {
            return TypeIndexingAvailability(sdkSettings: nil, sourceKitPath: nil, unavailabilityReason: .noDeveloperDirectory)
        }
        let sourceKitPath = SourceKitLocator.sourceKitPath(inDeveloperDirectory: developerDirectoryPath, fileExists: fileExists)
        guard let platformSDKSettings = try? sdkSettings(platform) else {
            return TypeIndexingAvailability(sdkSettings: nil, sourceKitPath: sourceKitPath, unavailabilityReason: .sdkNotInstalled(platform))
        }
        return TypeIndexingAvailability(sdkSettings: platformSDKSettings, sourceKitPath: sourceKitPath, unavailabilityReason: nil)
    }
}

#endif
