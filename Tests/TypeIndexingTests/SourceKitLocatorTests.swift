#if os(macOS)

import Foundation
import Testing
@testable import TypeIndexing

/// Where sourcekitd lives in a developer directory. An Xcode keeps it in its
/// default toolchain; the Command Line Tools have no `Toolchains` level, so
/// the path Xcode uses never exists there.
@Suite
struct SourceKitLocatorTests {
    private static let xcodeDeveloperDirectory = "/Applications/Xcode.app/Contents/Developer"
    private static let commandLineToolsDirectory = "/Library/Developer/CommandLineTools"

    @Test
    func sourceKitIsFoundInXcodeToolchainLayout() {
        let expectedPath = Self.xcodeDeveloperDirectory + "/Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitd.framework/Versions/A/sourcekitd"
        let foundPath = SourceKitLocator.sourceKitPath(inDeveloperDirectory: Self.xcodeDeveloperDirectory) { $0 == expectedPath }
        #expect(foundPath == expectedPath)
    }

    @Test
    func sourceKitIsFoundInCommandLineToolsLayout() {
        let expectedPath = Self.commandLineToolsDirectory + "/usr/lib/sourcekitd.framework/Versions/A/sourcekitd"
        let foundPath = SourceKitLocator.sourceKitPath(inDeveloperDirectory: Self.commandLineToolsDirectory) { $0 == expectedPath }
        #expect(foundPath == expectedPath)
    }

    @Test
    func xcodeToolchainWinsWhenBothLayoutsExist() {
        let foundPath = SourceKitLocator.sourceKitPath(inDeveloperDirectory: Self.xcodeDeveloperDirectory) { _ in true }
        #expect(foundPath == Self.xcodeDeveloperDirectory + "/Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitd.framework/Versions/A/sourcekitd")
    }

    @Test
    func developerDirectoryWithoutSourceKitFindsNothing() {
        #expect(SourceKitLocator.sourceKitPath(inDeveloperDirectory: Self.commandLineToolsDirectory) { _ in false } == nil)
    }

    /// A trailing slash, as `DEVELOPER_DIR` is sometimes written, makes no
    /// difference.
    @Test
    func trailingSlashIsIgnored() {
        let expectedPath = Self.commandLineToolsDirectory + "/usr/lib/sourcekitd.framework/Versions/A/sourcekitd"
        let foundPath = SourceKitLocator.sourceKitPath(inDeveloperDirectory: Self.commandLineToolsDirectory + "/") { $0 == expectedPath }
        #expect(foundPath == expectedPath)
    }
}

#endif
