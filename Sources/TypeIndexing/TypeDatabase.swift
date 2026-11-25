#if os(macOS)

import Foundation
import FoundationToolbox

/// Answers, for the C and Objective-C types a Swift mangling spells as
/// `__C.X` / `__ObjC.X`, which module declares `X` and what Swift calls it.
///
/// Attribution merges three sources, consulted in priority order:
///
/// 1. **API notes** — every entity an SDK `.apinotes` file lists, by C name
///    and by renamed Swift spelling. A module's API notes are the compiler's
///    own record of what it declares, so they outrank everything else.
/// 2. **Module interfaces** — type names extracted from sourcekitd-generated
///    module interfaces (the Swift view of each module, Objective-C imports
///    included), for the modules passed to ``index(dependencies:moduleFilter:)``.
///    Skipped when the developer directory has no sourcekitd.
/// 3. **Runtime metadata (lazy)** — names the dependency images declare
///    (``DeclaredTypeNameSource``), for private types no SDK file mentions.
///    Consulted only on a miss of the first two, one image at a time, stopping
///    at the first image that declares the name.
///
/// It also answers, for a Swift type the SDK moved between modules
/// (`@_originallyDefinedIn`), which module declares it now:
/// ``declaringModuleName(ofMovedTypeNamed:originallyDefinedIn:builtAgainst:)``,
/// read from the textual interfaces of every SDK module.
///
/// ``index(dependencies:moduleFilter:)`` may be called more than once: the
/// SDK is discovered and its API notes and moved types registered on the
/// first call, and every call adds the modules and dependency images it has
/// not seen yet.
@available(macOS 13.0, *)
public actor TypeDatabase {
    private let platform: SDKPlatform

    /// Where the module-interface cache lives; `nil` for the package's own
    /// directory in Application Support.
    private let cacheDirectoryURL: URL?

    /// User-supplied supplementary API notes locations (files or directories),
    /// loaded after the SDK's own so they overwrite them. The package ships no
    /// mappings of its own.
    private let supplementaryAPINotesURLs: [URL]

    private let sourceKitManager = SourceKitManager()

    /// Type name → declaring module, from API notes: C names first, then the
    /// renamed Swift spellings. Outranks ``interfaceModuleNamesByTypeName``.
    private var apiNotesModuleNamesByTypeName: [String: String] = [:]

    /// Type name → declaring module, from module interfaces.
    private var interfaceModuleNamesByTypeName: [String: String] = [:]

    /// Type name → image-derived module, filled lazily from the dependency
    /// images.
    private var runtimeModuleNamesByTypeName: [String: String] = [:]

    private var apiNotesIndex = APINotesIndex(files: [])

    /// The Swift types the SDK's modules declare under
    /// `@_originallyDefinedIn` another module, by the module their mangling
    /// names and their name. Read from every module's textual interface on
    /// the first ``index(dependencies:moduleFilter:)`` call.
    private var movedTypeDeclarationsByKey: [MovedTypeKey: MovedTypeDeclaration] = [:]

    /// The SDK's modules and API notes files, discovered on the first
    /// ``index(dependencies:moduleFilter:)`` call.
    private var sdkDiscovery: (settings: SDKSettings, discovery: SDKDiscovery)?

    /// Modules whose interfaces an earlier call indexed or is indexing.
    private var indexedModuleNames: Set<String> = []

    /// Dependency images not yet read, in registration order. Popped one at a
    /// time as misses demand; a source that throws is dropped, not retried.
    private var unindexedDependencies: [any DeclaredTypeNameSource] = []

    /// Image paths ever registered, so a repeated registration adds nothing.
    private var registeredDependencyImagePaths: Set<String> = []

    /// Whether the missing sourcekitd was logged, so it is logged once.
    private var hasLoggedMissingSourceKit = false

    /// - Parameters:
    ///   - platform: The SDK whose API notes and module interfaces are read.
    ///   - cacheDirectory: The directory the module-interface cache is kept
    ///     in, one subdirectory per platform and SDK build. `nil` keeps it in
    ///     `~/Library/Application Support/swift-type-indexing/SDKIndexer`.
    ///   - supplementaryAPINotesURLs: `.apinotes` files, or directories of
    ///     them, loaded after the SDK's own so they overwrite them — mappings
    ///     for frameworks the SDK has no module for.
    public init(platform: SDKPlatform, cacheDirectory: URL? = nil, supplementaryAPINotesURLs: [URL] = []) {
        self.platform = platform
        self.cacheDirectoryURL = cacheDirectory
        self.supplementaryAPINotesURLs = supplementaryAPINotesURLs
    }

    // MARK: - Indexing

    /// Adds `dependencies` and the interfaces of the SDK modules passing
    /// `moduleFilter` to the database.
    ///
    /// The first call discovers the SDK (cheap) and registers its API notes;
    /// every call then generates and extracts interfaces only for the modules
    /// it has not indexed yet (expensive, cached per module per SDK build) and
    /// appends the dependency images it has not seen. Throws only when the
    /// platform's SDK cannot be found; a module whose interface cannot be
    /// generated is skipped. Without sourcekitd only the modules already in
    /// the cache contribute interface names.
    public func index(dependencies: [any DeclaredTypeNameSource], moduleFilter: @Sendable (String) -> Bool) async throws {
        let (sdkSettings, discovery) = try discoverSDK()

        let modulesToIndex = discovery.modules.filter { moduleFilter($0.moduleName) && !indexedModuleNames.contains($0.moduleName) }
        indexedModuleNames.formUnion(modulesToIndex.map(\.moduleName))
        let cache = ModuleIndexCache(platform: platform, sdkSettings: sdkSettings, rootDirectoryURL: cacheDirectoryURL)
        let moduleInterfaceIndexer: ModuleInterfaceIndexer
        if SourceKitLocator.activeSourceKitPath() != nil {
            moduleInterfaceIndexer = ModuleInterfaceIndexer(platform: platform, sdkSettings: sdkSettings, cache: cache, sourceKitManager: sourceKitManager)
        } else {
            if !hasLoggedMissingSourceKit {
                hasLoggedMissingSourceKit = true
                #log(.info, "No sourcekitd in the active developer directory; module interfaces come from the cache only")
            }
            moduleInterfaceIndexer = ModuleInterfaceIndexer(platform: platform, sdkSettings: sdkSettings, cache: cache, interfaceGenerator: nil)
        }
        let collectedEntries = await withTaskGroup(of: ModuleIndexCacheEntry?.self) { group in
            for moduleDescriptor in modulesToIndex {
                group.addTask {
                    await moduleInterfaceIndexer.indexEntry(forModuleNamed: moduleDescriptor.moduleName)
                }
            }
            var entries: [ModuleIndexCacheEntry] = []
            for await entry in group {
                if let entry {
                    entries.append(entry)
                }
            }
            return entries
        }
        register(moduleEntries: Self.entriesInDiscoveryOrder(collectedEntries, discoveryOrder: modulesToIndex.map(\.moduleName)))
        register(dependencies: dependencies)
    }

    /// The SDK's discovery, made and its API notes registered on first use.
    private func discoverSDK() throws -> (SDKSettings, SDKDiscovery) {
        if let sdkDiscovery {
            return (sdkDiscovery.settings, sdkDiscovery.discovery)
        }
        let sdkSettings = try platform.sdkSettings()
        let discovery = SDKIndexer(platform: platform).discover(sdkSettings: sdkSettings)
        sdkDiscovery = (sdkSettings, discovery)
        register(apiNotesIndex: APINotesIndex(files: discovery.apiNotesFiles))
        register(supplementaryAPINotesFiles: SupplementaryAPINotesLoader.files(atSupplementaryLocations: supplementaryAPINotesURLs))
        // Every module, not only the ones a binary links: a moved type's
        // module is often not linked directly (a binary naming `SwiftUI.View`
        // need not link SwiftUICore), and the scan reads text, no sourcekitd.
        register(movedTypeDeclarations: MovedTypeIndex.movedTypeDeclarations(inModules: discovery.modules, platform: platform))
        return (sdkSettings, discovery)
    }

    /// Registers the moves the SDK's interfaces declare. Exposed as a step so
    /// lookup is unit-testable without an SDK. The first registration of a
    /// key wins — discovery order, which is the search paths' priority — and
    /// a second module claiming the same key is logged.
    func register(movedTypeDeclarations: [MovedTypeDeclaration]) {
        for movedTypeDeclaration in movedTypeDeclarations {
            let key = movedTypeDeclaration.key
            if let registeredDeclaration = movedTypeDeclarationsByKey[key] {
                if registeredDeclaration.declaringModuleName != movedTypeDeclaration.declaringModuleName {
                    #log(.info, "\(key.originalModuleName, privacy: .public).\(key.typeName, privacy: .public) is declared moved by both \(registeredDeclaration.declaringModuleName, privacy: .public) and \(movedTypeDeclaration.declaringModuleName, privacy: .public); keeping the first")
                }
                continue
            }
            movedTypeDeclarationsByKey[key] = movedTypeDeclaration
        }
    }

    /// Restores discovery order over task-group results: the group yields
    /// entries in COMPLETION order, which varies with per-module cache hits —
    /// but registration is last-writer-wins, so it must follow the discovery
    /// order (SDKIndexer's search-path priority: "an earlier hit wins a
    /// module-name tie"), or two runs could attribute a tied name
    /// differently.
    static func entriesInDiscoveryOrder(_ collectedEntries: [ModuleIndexCacheEntry], discoveryOrder moduleNames: [String]) -> [ModuleIndexCacheEntry] {
        let entriesByModuleName = Dictionary(collectedEntries.map { ($0.moduleName, $0) }, uniquingKeysWith: { firstEntry, _ in firstEntry })
        return moduleNames.compactMap { entriesByModuleName[$0] }
    }

    /// Registers interface-extracted type names. Exposed as a step so merge
    /// priority is unit-testable without sourcekitd.
    func register(moduleEntries: [ModuleIndexCacheEntry]) {
        for entry in moduleEntries {
            for typeName in entry.typeNames {
                interfaceModuleNamesByTypeName[typeName] = entry.moduleName
            }
        }
    }

    /// Registers API notes attribution (C name → declaring module), which
    /// outranks any interface-derived entry for the same name whichever is
    /// registered first.
    func register(apiNotesIndex: APINotesIndex) {
        self.apiNotesIndex = apiNotesIndex
        registerAttribution(fromAPINotesIndex: apiNotesIndex)
    }

    /// Registers supplementary API notes files on top of whatever is already
    /// indexed: their entries append into the same `APINotesIndex`, where
    /// later files overwrite earlier same-name entries — so calling this after
    /// `register(apiNotesIndex:)` gives supplementary mappings the last word
    /// over SDK ones. Attribution is then re-synced from the index, whose
    /// internal ordering already reflects the override.
    func register(supplementaryAPINotesFiles supplementaryFiles: [APINotesFile]) {
        apiNotesIndex.register(files: supplementaryFiles)
        registerAttribution(fromAPINotesIndex: apiNotesIndex)
    }

    private func registerAttribution(fromAPINotesIndex attributionIndex: APINotesIndex) {
        for (cName, moduleName) in attributionIndex.moduleNamesByCName {
            apiNotesModuleNamesByTypeName[cName] = moduleName
        }
        // Swift spellings too, after the C spellings. A printed `__C` name no
        // longer carries one: a foreign descriptor records the imported
        // spelling (`Graph` for an `AG_SWIFT_NAME(Graph)` type), but the
        // demangler names it by the ABI name in its import info. What this
        // pass still decides is a C name several modules' API notes list.
        // Foundation's and AppKit's list `NSObject` only to annotate category
        // methods, and the pass above lets whichever file came last win;
        // ObjectiveC's entry renames `NSObject` to itself, so registering that
        // spelling last gives the class back to ObjectiveC. Nested renames
        // (`ProcessInfo.ActivityOptions`) never appear as one identifier and
        // are skipped.
        for (swiftName, originalCName) in attributionIndex.cNamesBySwiftName where !swiftName.contains(".") {
            apiNotesModuleNamesByTypeName[swiftName] = originalCName.moduleName
        }
    }

    /// Appends dependency images consulted lazily for private-type
    /// attribution, skipping any image registered before.
    func register(dependencies: [any DeclaredTypeNameSource]) {
        for dependency in dependencies where registeredDependencyImagePaths.insert(dependency.imagePath).inserted {
            unindexedDependencies.append(dependency)
        }
    }

    // MARK: - Query

    /// The module that declares the C or Objective-C type `typeName`, or `nil`
    /// when no source attributes it.
    public func moduleName(forTypeName typeName: String) async -> String? {
        if let moduleName = indexedModuleName(forTypeName: typeName) {
            return moduleName
        }
        if let moduleName = runtimeModuleNamesByTypeName[typeName] {
            return moduleName
        }
        // Fold in one dependency image at a time until the name resolves or
        // the images run out. Misses after exhaustion cost one dictionary
        // probe, since nothing remains unread.
        while !unindexedDependencies.isEmpty {
            let dependency = unindexedDependencies.removeFirst()
            await registerDeclaredTypeNames(of: dependency)
            if let moduleName = runtimeModuleNamesByTypeName[typeName] {
                return moduleName
            }
        }
        return nil
    }

    /// The attribution API notes or module interfaces give `typeName`, API
    /// notes first.
    private func indexedModuleName(forTypeName typeName: String) -> String? {
        apiNotesModuleNamesByTypeName[typeName] ?? interfaceModuleNamesByTypeName[typeName]
    }

    /// The Swift spelling of a C-imported type name, when it differs from the
    /// C one. Two sources, in order:
    ///
    /// 1. **API notes renames**, per declaration category (`NSDecimal` →
    ///    `Decimal`; the protocol-only `NSObject` → `NSObjectProtocol` rename
    ///    never touches class references).
    /// 2. **The CF bridge rule**: ClangImporter imports a `CF…Ref` typedef as
    ///    the `Ref`-stripped native class (`CFStringRef` → `CFString`), while
    ///    manglings record the C spelling. The stripped name qualifies only
    ///    when it actually exists in the attribution tables — so an
    ///    Objective-C class that merely happens to end in `Ref` is never
    ///    rewritten — and never applies to protocol references (there is no
    ///    CF protocol convention).
    public func swiftName(forCName cName: String, category: ImportedTypeNameCategory) -> String? {
        if let renamedName = apiNotesIndex.swiftName(forCName: cName, category: category) {
            return renamedName.name
        }
        if category != .objcProtocol, cName.hasSuffix("Ref") {
            let strippedName = String(cName.dropLast(3))
            if !strippedName.isEmpty, indexedModuleName(forTypeName: strippedName) != nil {
                return strippedName
            }
        }
        return nil
    }

    /// What API notes say about how Swift imports the Objective-C class
    /// `className` and its members, or `nil` when they say nothing.
    ///
    /// Comes from API notes alone, so an ``index(dependencies:moduleFilter:)``
    /// call that indexes no module (`moduleFilter` returning `false`) is
    /// enough, and needs no sourcekitd.
    public func swiftImportAnnotations(forObjCClassNamed className: String) -> ObjCContainerSwiftImportAnnotations? {
        apiNotesIndex.swiftImportAnnotations(forObjCClassNamed: className)
    }

    /// The same for the Objective-C protocol `protocolName`.
    public func swiftImportAnnotations(forObjCProtocolNamed protocolName: String) -> ObjCContainerSwiftImportAnnotations? {
        apiNotesIndex.swiftImportAnnotations(forObjCProtocolNamed: protocolName)
    }

    /// The module that declares the Swift type a mangling names
    /// `originalModuleName.typeName`, when the SDK moved it there
    /// (`@_originallyDefinedIn(module: originalModuleName, …)`) no later than
    /// `sdkVersion` of the database's platform; `nil` when it never moved,
    /// moved later, or the database is not indexed yet.
    ///
    /// The compiler mangles a moved type — and every type nested in it —
    /// under the module it was originally defined in, on every deployment
    /// target, so a binary only ever spells `CoreGraphics.CGFloat`; the SDK's
    /// interfaces spell `CoreFoundation.CGFloat`. Pass the SDK version the
    /// binary was built with (its `LC_BUILD_VERSION`), so a binary built
    /// before a move keeps the module its SDK declared the type in:
    ///
    /// ```swift
    /// await typeDatabase.declaringModuleName(ofMovedTypeNamed: "View", originallyDefinedIn: "SwiftUI", builtAgainst: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    /// // "SwiftUICore"; nil for a binary built with the macOS 14 SDK
    /// ```
    ///
    /// `typeName` is the top-level type's name; a nested type is looked up by
    /// its outermost type. Comes from text alone, so an
    /// ``index(dependencies:moduleFilter:)`` call that indexes no module is
    /// enough, and needs no sourcekitd.
    public func declaringModuleName(ofMovedTypeNamed typeName: String, originallyDefinedIn originalModuleName: String, builtAgainst sdkVersion: OperatingSystemVersion) -> String? {
        guard
            let movedTypeDeclaration = movedTypeDeclarationsByKey[MovedTypeKey(originalModuleName: originalModuleName, typeName: typeName)],
            let movedVersion = movedTypeDeclaration.movedVersion(on: platform),
            PlatformVersion(sdkVersion) >= movedVersion
        else {
            return nil
        }
        return movedTypeDeclaration.declaringModuleName
    }

    // MARK: - Runtime Metadata

    private func registerDeclaredTypeNames(of dependency: any DeclaredTypeNameSource) async {
        let imagePath = dependency.imagePath
        let moduleName = Self.moduleName(forImagePath: imagePath)
        let declaredNames: [String]
        do {
            declaredNames = try await dependency.declaredTypeNames()
        } catch {
            #log(.error, "Skipping the declared types of \(imagePath, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        for declaredName in declaredNames {
            // Never overwrite: the declaring image is whichever dependency
            // came first in registration order, and API notes and interface
            // attribution are consulted before this table anyway.
            if runtimeModuleNamesByTypeName[declaredName] == nil {
                runtimeModuleNamesByTypeName[declaredName] = moduleName
            }
        }
    }

    /// `…/Foundation.framework/Foundation` → `Foundation`,
    /// `libswiftFoundation.dylib` → `Foundation`, `libobjc.A.dylib` →
    /// `libobjc`: every path extension is stripped, then the `libswift`
    /// overlay prefix is removed.
    public static func moduleName(forImagePath imagePath: String) -> String {
        var name = URL(fileURLWithPath: imagePath).lastPathComponent
        while name.contains(".") {
            // A leading-dot name is a fixed point of extension stripping
            // (`.hidden` → `.hidden`) — without this guard the loop spins
            // forever on such an install name.
            let strippedName = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            guard strippedName != name, !strippedName.isEmpty else { break }
            name = strippedName
        }
        if name.hasPrefix("libswift") {
            name = String(name.dropFirst("libswift".count))
        }
        return name
    }
}

// Protocol-form `@Loggable`: the type carries an `@available(macOS 13.0, *)`
// scope the macro's own annotations would exceed. The protocol itself stays
// un-annotated for that reason.
@Loggable(.fileprivate, subsystem: "com.mxiris.type-indexing", category: "TypeDatabase")
fileprivate protocol TypeDatabaseLogging {}

@available(macOS 13.0, *)
extension TypeDatabase: TypeDatabaseLogging {}

#endif
