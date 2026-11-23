#if os(macOS)

import Foundation
import Testing
@testable import TypeIndexing

/// Mac Catalyst has no SDK of its own: it is the macOS SDK read through its
/// `System/iOSSupport` tree, where UIKit and its API notes live, with an
/// `ios…-macabi` target.
@Suite
struct MacCatalystPlatformTests {
    @Test
    func macCatalystReadsTheMacOSSDK() {
        #expect(SDKPlatform.macCatalyst.xcrunSDKName == "macosx")
        #expect(SDKPlatform.macOS.xcrunSDKName == "macosx")
        #expect(SDKPlatform.iOS.xcrunSDKName == "iphoneos")
    }

    @Test
    func macCatalystSearchesIOSSupportFirst() {
        let searchPaths = SDKIndexer(platform: .macCatalyst).searchPaths
        #expect(searchPaths.first == "System/iOSSupport/usr/include")
        #expect(searchPaths.contains("System/iOSSupport/System/Library/Frameworks"))
        #expect(searchPaths.contains("System/Library/Frameworks"))
        let iOSSupportIndex = searchPaths.firstIndex(of: "System/iOSSupport/System/Library/Frameworks")
        let macOSIndex = searchPaths.firstIndex(of: "System/Library/Frameworks")
        #expect(iOSSupportIndex! < macOSIndex!)
        #expect(!SDKIndexer(platform: .macOS).searchPaths.contains { $0.hasPrefix("System/iOSSupport") })
    }

    @Test
    func macCatalystTargetTripleIsMacABI() {
        let sdkSettings = SDKSettings(sdkPath: "/nonexistent-sdk", version: "15.6", productBuildVersion: nil, macCatalystVersion: "18.6")
        #expect(sdkSettings.targetTriple(for: .macCatalyst).hasSuffix("-apple-ios18.6-macabi"))
        #expect(sdkSettings.targetTriple(for: .macOS).hasSuffix("-apple-macos15.6"))
    }

    @Test
    func macCatalystVersionIsReadFromSDKSettings() throws {
        let sdkDirectoryURL = FileManager.default.temporaryDirectory
            .appending(component: "MacCatalystPlatformTests-\(UUID().uuidString).sdk")
        try FileManager.default.createDirectory(at: sdkDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sdkDirectoryURL) }
        let settingsPlist: [String: Any] = [
            "Version": "15.6",
            "ProductBuildVersion": "24G90",
            "SupportedTargets": ["iosmac": ["DefaultDeploymentTarget": "18.6"]],
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: settingsPlist, format: .xml, options: 0)
        try plistData.write(to: sdkDirectoryURL.appending(component: "SDKSettings.plist"))

        let sdkSettings = try SDKSettings(sdkPath: sdkDirectoryURL.path(percentEncoded: false))
        #expect(sdkSettings.macCatalystVersion == "18.6")
        #expect(sdkSettings.targetTriple(for: .macCatalyst).hasSuffix("-apple-ios18.6-macabi"))
    }

    /// From macOS 26 on the two versions are the same; an SDK that names no
    /// Mac Catalyst version gets the macOS one.
    @Test
    func missingMacCatalystVersionFallsBackToTheSDKVersion() {
        let sdkSettings = SDKSettings(sdkPath: "/nonexistent-sdk", version: "27.2", productBuildVersion: nil)
        #expect(sdkSettings.targetTriple(for: .macCatalyst).hasSuffix("-apple-ios27.2-macabi"))
    }

    /// sourcekitd takes its arguments as a frontend invocation, without the
    /// driver that adds a Mac Catalyst target's iOSSupport frameworks: without
    /// them UIKit's interface failed with "Could not load module: UIKit".
    @Test
    func macCatalystInterfaceGenerationSeesIOSSupportFrameworks() {
        let sdkSettings = SDKSettings(sdkPath: "/SDKs/MacOSX.sdk", version: "27.2", productBuildVersion: nil)
        let catalystArguments = sdkSettings.compilerArguments(for: .macCatalyst)
        #expect(catalystArguments.starts(with: ["-sdk", "/SDKs/MacOSX.sdk", "-target"]))
        #expect(catalystArguments.contains("/SDKs/MacOSX.sdk/System/iOSSupport/System/Library/Frameworks"))
        let frameworkFlagIndex = catalystArguments.firstIndex(of: "-Fsystem")
        #expect(frameworkFlagIndex.map { catalystArguments[$0 + 1] } == "/SDKs/MacOSX.sdk/System/iOSSupport/System/Library/Frameworks")
        #expect(!sdkSettings.compilerArguments(for: .macOS).contains("-Fsystem"))
    }

    /// Mac Catalyst caches apart from macOS: the same SDK yields different
    /// module interfaces for the two targets.
    @Test
    func macCatalystCachesApartFromMacOS() {
        let sdkSettings = SDKSettings(sdkPath: "/nonexistent-sdk", version: "27.2", productBuildVersion: "27C5")
        let rootDirectoryURL = URL(fileURLWithPath: "/nonexistent-cache")
        let catalystCache = ModuleIndexCache(platform: .macCatalyst, sdkSettings: sdkSettings, rootDirectoryURL: rootDirectoryURL)
        let macOSCache = ModuleIndexCache(platform: .macOS, sdkSettings: sdkSettings, rootDirectoryURL: rootDirectoryURL)
        #expect(catalystCache.directoryURL != macOSCache.directoryURL)
    }
}

#endif
