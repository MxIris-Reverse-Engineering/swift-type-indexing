#if os(macOS)

import Foundation
import Testing
@testable import TypeIndexing

/// Where module-interface entries are cached, and what an indexer without
/// sourcekitd does with the cache.
@Suite
struct CacheDirectoryTests {
    private static let sdkSettings = SDKSettings(sdkPath: "/nonexistent-sdk", version: "27.2", productBuildVersion: "27C5")

    private static func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(component: "CacheDirectoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    @Test
    func cacheEntriesAreWrittenUnderTheGivenDirectory() throws {
        let rootDirectoryURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectoryURL) }

        let cache = ModuleIndexCache(platform: .macOS, sdkSettings: Self.sdkSettings, rootDirectoryURL: rootDirectoryURL)
        cache.store(ModuleIndexCacheEntry(moduleName: "Foundation", typeNames: ["NSString"], subModuleNames: []))

        let expectedEntryPath = rootDirectoryURL
            .appending(component: "macosx")
            .appending(component: "27.2-27C5")
            .appending(component: "Foundation.json")
            .path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: expectedEntryPath))
        #expect(cache.entry(forModuleNamed: "Foundation")?.typeNames == ["NSString"])
    }

    @Test
    func defaultRootIsThePackagesOwnApplicationSupportDirectory() {
        let cache = ModuleIndexCache(platform: .iOS, sdkSettings: Self.sdkSettings, rootDirectoryURL: nil)
        let pathComponents = cache.directoryURL.pathComponents.suffix(4)
        #expect(Array(pathComponents) == ["swift-type-indexing", "SDKIndexer", "iphoneos", "27.2-27C5"])
    }

    /// Without sourcekitd an indexer serves what the cache holds and skips
    /// the rest, without trying to generate anything.
    @Test
    func missingSourceKitServesCachedEntriesOnly() async throws {
        let rootDirectoryURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectoryURL) }
        let cache = ModuleIndexCache(platform: .macOS, sdkSettings: Self.sdkSettings, rootDirectoryURL: rootDirectoryURL)
        cache.store(ModuleIndexCacheEntry(moduleName: "Cached", typeNames: ["CachedType"], subModuleNames: []))

        let indexer = ModuleInterfaceIndexer(platform: .macOS, sdkSettings: Self.sdkSettings, cache: cache, interfaceGenerator: nil)
        #expect(await indexer.indexEntry(forModuleNamed: "Cached")?.typeNames == ["CachedType"])
        #expect(await indexer.indexEntry(forModuleNamed: "Uncached") == nil)
    }
}

#endif
