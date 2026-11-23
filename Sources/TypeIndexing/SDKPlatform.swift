#if os(macOS)

import Foundation

/// An Apple platform whose SDK the indexer reads, named by its `xcrun --sdk`
/// identifier — except Mac Catalyst, which has no SDK of its own: it is the
/// macOS SDK read through its `System/iOSSupport` tree.
@available(macOS 13.0, *)
public enum SDKPlatform: String, CaseIterable, Hashable, Codable, Sendable {
    case macOS = "macosx"
    /// The macOS SDK as a Mac Catalyst build sees it: UIKit and the other
    /// iOS frameworks from `System/iOSSupport`, an `ios…-macabi` target.
    case macCatalyst = "maccatalyst"
    case iOS = "iphoneos"
    case tvOS = "appletvos"
    case watchOS = "watchos"
    case visionOS = "xros"
    case driverKit = "driverkit"
    case iOSSimulator = "iphonesimulator"
    case tvOSSimulator = "appletvsimulator"
    case watchOSSimulator = "watchsimulator"
    case visionOSSimulator = "xrsimulator"

    /// The `xcrun --sdk` name of the SDK this platform's headers come from.
    var xcrunSDKName: String {
        switch self {
        case .macCatalyst:
            return SDKPlatform.macOS.rawValue
        default:
            return rawValue
        }
    }

    /// The on-disk root of this platform's SDK in the active developer
    /// directory.
    public func sdkPath() throws -> String {
        try Subprocess.xcrun(["--show-sdk-path", "--sdk", xcrunSDKName])
    }

    /// The settings of this platform's SDK in the active Xcode. Reads
    /// `SDKSettings.plist` once per call; callers cache the result.
    public func sdkSettings() throws -> SDKSettings {
        try SDKSettings(sdkPath: sdkPath())
    }
}

/// The subset of an SDK's `SDKSettings.plist` the indexer consumes: enough to
/// form a compiler target triple and to version the on-disk index cache.
@available(macOS 13.0, *)
public struct SDKSettings: Sendable, Hashable {
    public let sdkPath: String

    /// The SDK's marketing version, e.g. `26.5`.
    public let version: String

    /// The SDK's build identifier, e.g. `25F76`. Distinguishes beta builds
    /// that share a marketing version. Absent from some SDKs.
    public let productBuildVersion: String?

    /// The iOS version a Mac Catalyst build against this SDK targets by
    /// default (`SupportedTargets.iosmac.DefaultDeploymentTarget`), e.g.
    /// `18.6` for the macOS 15.6 SDK. Absent from SDKs without Mac Catalyst;
    /// from macOS 26 on it equals ``version``.
    public let macCatalystVersion: String?

    enum Error: Swift.Error {
        case malformedSDKSettings(path: String)
    }

    /// Test seam: constructs settings without reading an `SDKSettings.plist`.
    init(sdkPath: String, version: String, productBuildVersion: String?, macCatalystVersion: String? = nil) {
        self.sdkPath = sdkPath
        self.version = version
        self.productBuildVersion = productBuildVersion
        self.macCatalystVersion = macCatalystVersion
    }

    public init(sdkPath: String) throws {
        let settingsPlistURL = URL(fileURLWithPath: sdkPath).appending(component: "SDKSettings.plist")
        let settingsPlistData = try Data(contentsOf: settingsPlistURL)
        guard
            let settingsPlist = try PropertyListSerialization.propertyList(from: settingsPlistData, format: nil) as? [String: Any],
            let version = settingsPlist["Version"] as? String
        else {
            throw Error.malformedSDKSettings(path: settingsPlistURL.path(percentEncoded: false))
        }
        self.sdkPath = sdkPath
        self.version = version
        self.productBuildVersion = settingsPlist["ProductBuildVersion"] as? String
        let supportedTargets = settingsPlist["SupportedTargets"] as? [String: Any]
        let macCatalystTarget = supportedTargets?["iosmac"] as? [String: Any]
        self.macCatalystVersion = macCatalystTarget?["DefaultDeploymentTarget"] as? String
    }

    /// One path component identifying this exact SDK build, used to segment
    /// the on-disk index cache so an Xcode update never serves stale entries.
    public var cacheDirectoryComponent: String {
        if let productBuildVersion {
            return "\(version)-\(productBuildVersion)"
        }
        return version
    }

    /// The compiler target triple for `platform` at this SDK's version, for
    /// the host architecture.
    func targetTriple(for platform: SDKPlatform) -> String {
        let architecture: String
        #if arch(x86_64)
        architecture = "x86_64"
        #elseif arch(arm64)
        architecture = "arm64"
        #else
        architecture = "unknown"
        #endif
        switch platform {
        case .macOS:
            return "\(architecture)-apple-macos\(version)"
        case .macCatalyst:
            return "\(architecture)-apple-ios\(macCatalystVersion ?? version)-macabi"
        case .iOS:
            return "\(architecture)-apple-ios\(version)"
        case .tvOS:
            return "\(architecture)-apple-tvos\(version)"
        case .watchOS:
            return "\(architecture)-apple-watchos\(version)"
        case .visionOS:
            return "\(architecture)-apple-xros\(version)"
        case .driverKit:
            return "\(architecture)-apple-driverkit\(version)"
        case .iOSSimulator:
            return "\(architecture)-apple-ios\(version)-simulator"
        case .tvOSSimulator:
            return "\(architecture)-apple-tvos\(version)-simulator"
        case .watchOSSimulator:
            return "\(architecture)-apple-watchos\(version)-simulator"
        case .visionOSSimulator:
            return "\(architecture)-apple-xros\(version)-simulator"
        }
    }
}

#endif
