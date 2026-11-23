#if os(macOS)

import Foundation
import FoundationToolbox

/// The per-module indexing pipeline: cache lookup → interface generation →
/// type-name extraction → cache store. Runs only for modules the caller's
/// dependency filter selected — this is where the expensive sourcekitd work
/// lives, deliberately downstream of the filter.
@available(macOS 13.0, *)
struct ModuleInterfaceIndexer: Sendable {
    typealias InterfaceGenerator = @Sendable (_ moduleName: String) async throws -> SourceKitManager.GeneratedModuleInterface

    let platform: SDKPlatform
    let sdkSettings: SDKSettings
    let cache: ModuleIndexCache
    /// `nil` when the developer directory has no sourcekitd: the indexer
    /// then serves cached entries only.
    private let generateInterface: InterfaceGenerator?

    init(platform: SDKPlatform, sdkSettings: SDKSettings, cache: ModuleIndexCache, sourceKitManager: SourceKitManager) {
        self.init(platform: platform, sdkSettings: sdkSettings, cache: cache) { moduleName in
            try await sourceKitManager.interface(for: moduleName, platform: platform, sdkSettings: sdkSettings)
        }
    }

    /// Substitutes the sourcekitd-backed generation with an arbitrary
    /// closure — the seam tests use to check the cache-write discipline
    /// (partial entries are never stored) without sourcekitd — or with `nil`,
    /// which serves cached entries only and generates nothing.
    init(platform: SDKPlatform, sdkSettings: SDKSettings, cache: ModuleIndexCache, interfaceGenerator: InterfaceGenerator?) {
        self.platform = platform
        self.sdkSettings = sdkSettings
        self.cache = cache
        self.generateInterface = interfaceGenerator
    }

    /// Indexes one module, returning `nil` when its interface cannot be
    /// generated — the caller skips that module rather than failing the whole
    /// indexing run (one exotic module must not blank the entire database).
    ///
    /// Submodule interfaces (`Foundation.NSObject`-style imports of the
    /// module's own submodules) are generated and folded into the same entry:
    /// attribution always names the top-level module, which is what a
    /// qualified `Foundation.NSString` spelling needs.
    func indexEntry(forModuleNamed moduleName: String) async -> ModuleIndexCacheEntry? {
        if let cachedEntry = cache.entry(forModuleNamed: moduleName) {
            return cachedEntry
        }
        guard let generateInterface else {
            return nil
        }
        do {
            let interface = try await generateInterface(moduleName)
            var typeNames = InterfaceTypeNameExtractor.fullyQualifiedTypeNames(in: interface.declarations)
            let subModulePrefix = "\(moduleName)."
            let subModuleNames = interface.importedModuleNames.filter { $0.hasPrefix(subModulePrefix) }
            var allSubModulesSucceeded = true
            for subModuleName in subModuleNames {
                do {
                    let subModuleInterface = try await generateInterface(subModuleName)
                    typeNames.append(contentsOf: InterfaceTypeNameExtractor.fullyQualifiedTypeNames(in: subModuleInterface.declarations))
                } catch {
                    allSubModulesSucceeded = false
                    #log(.error, "Skipping submodule \(subModuleName, privacy: .public) of \(moduleName, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            let entry = ModuleIndexCacheEntry(moduleName: moduleName, typeNames: typeNames, subModuleNames: subModuleNames)
            // A partial entry (a submodule's generation failed, e.g. one
            // sourcekitd timeout) is served for THIS run but never cached:
            // the cache has no completeness marker, so storing it would
            // freeze the gap until the SDK or generator version changes.
            if allSubModulesSucceeded {
                cache.store(entry)
            } else {
                #log(.error, "Not caching partial entry for \(moduleName, privacy: .public); submodule extraction will retry next run")
            }
            return entry
        } catch {
            #log(.error, "Skipping module \(moduleName, privacy: .public): interface generation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

// Protocol-form `@Loggable` — see the note in SDKIndexer.swift: the direct
// type form clashes with the `@available(macOS 13.0, *)` scope.
@Loggable(.fileprivate, subsystem: "com.mxiris.type-indexing", category: "ModuleInterfaceIndexer")
fileprivate protocol ModuleInterfaceIndexerLogging {}

@available(macOS 13.0, *)
extension ModuleInterfaceIndexer: ModuleInterfaceIndexerLogging {}

#endif
