#if os(macOS)

import Csourcekitd
import Foundation
import FoundationToolbox
import SourceKitD

/// Generates whole-module Swift interfaces through sourcekitd's
/// `editor.open.interface` request — the same request Xcode's generated
/// interface uses, and the only ready-made way to obtain the *Swift view* of a
/// module including its ObjC-imported declarations (the SDK's
/// `.swiftinterface` files carry Swift declarations only).
///
/// The request is sent with `key.enablesubstructure`, and the response's
/// document-structure tree is converted into plain
/// ``InterfaceDeclarationNode`` values before it leaves the document service,
/// so downstream extraction never touches sourcekitd types.
///
/// **Every interface it opens it closes again, and it generates only a few at
/// a time.** SourceKitService keeps each opened interface — a context holding
/// two compiler instances with the module and everything it imports loaded,
/// about 1 GB for an SDK framework — until `editor.close` names the document.
/// Left open, they piled up for as long as the service lived: indexing
/// AppKit's dependencies took one SourceKitService to 27 GB in six seconds,
/// and RuntimeViewer's two services to 80 GB each. A closed interface leaves
/// the generations in flight as the only ones held, which
/// ``maximumConcurrentGenerations`` bounds.
@available(macOS 13.0, *)
actor SourceKitManager {
    struct GeneratedModuleInterface: Sendable {
        let moduleName: String
        let sourceText: String
        let declarations: [InterfaceDeclarationNode]

        /// Module names the generated interface imports, in appearance order.
        /// Submodule detection (`Foundation.NSObject` inside `Foundation`)
        /// filters on these.
        let importedModuleNames: [String]

        init(moduleName: String, sourceText: String, declarations: [InterfaceDeclarationNode], importedModuleNames: [String]) {
            self.moduleName = moduleName
            self.sourceText = sourceText
            self.declarations = declarations
            self.importedModuleNames = importedModuleNames
        }
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case missingSourceText(moduleName: String)
        case missingSubstructure(moduleName: String)
        case sourceKitNotFound

        var description: String {
            switch self {
            case .missingSourceText(let moduleName):
                return "editor.open.interface returned no source text for module \(moduleName)"
            case .missingSubstructure(let moduleName):
                return "editor.open.interface returned no substructure for module \(moduleName); the type-name extraction has no input"
            case .sourceKitNotFound:
                return "the active developer directory has no sourcekitd"
            }
        }
    }

    /// How many interfaces are generated at once unless the caller says
    /// otherwise. Each one in flight holds about 1 GB in SourceKitService, and
    /// sourcekitd gains little from more: generation is dominated by loading
    /// the same Clang modules over again.
    static let defaultMaximumConcurrentGenerations = 2

    private let documentService: any InterfaceDocumentService

    /// The most interface generations in flight at once, the open request and
    /// its close included.
    let maximumConcurrentGenerations: Int

    private var activeGenerationCount = 0

    /// Generations waiting for a slot, resumed first come, first served.
    private var generationSlotWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - documentService: Sends the open and close requests; sourcekitd
    ///     unless a test stands in for it.
    ///   - maximumConcurrentGenerations: At least 1.
    init(
        documentService: any InterfaceDocumentService = SourceKitDInterfaceDocumentService(),
        maximumConcurrentGenerations: Int = SourceKitManager.defaultMaximumConcurrentGenerations
    ) {
        self.documentService = documentService
        self.maximumConcurrentGenerations = max(1, maximumConcurrentGenerations)
    }

    /// Generates `moduleName`'s interface against `sdkSettings`' SDK and
    /// converts the structured response, then closes the interface document in
    /// SourceKitService — also when the generation fails, since a request that
    /// timed out may still have opened it. Waits while
    /// ``maximumConcurrentGenerations`` others are in flight. A large module
    /// takes seconds, which is why callers index only the modules a binary
    /// actually depends on and cache the extraction.
    func interface(
        for moduleName: String,
        platform: SDKPlatform,
        sdkSettings: SDKSettings
    ) async throws -> GeneratedModuleInterface {
        await acquireGenerationSlot()
        defer { releaseGenerationSlot() }

        let documentName = UUID().uuidString
        let result: Result<GeneratedModuleInterface, any Swift.Error>
        do {
            result = .success(try await documentService.openInterface(
                documentName: documentName,
                moduleName: moduleName,
                compilerArguments: sdkSettings.compilerArguments(for: platform)
            ))
        } catch {
            result = .failure(error)
        }
        do {
            try await documentService.closeInterface(documentName: documentName)
        } catch {
            #log(.error, "Could not close the interface of \(moduleName, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        return try result.get()
    }

    // MARK: - Generation Slots

    private func acquireGenerationSlot() async {
        if activeGenerationCount < maximumConcurrentGenerations {
            activeGenerationCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            generationSlotWaiters.append(continuation)
        }
        // The slot was handed over by `releaseGenerationSlot()`, which left
        // the count as it was.
    }

    private func releaseGenerationSlot() {
        if generationSlotWaiters.isEmpty {
            activeGenerationCount -= 1
        } else {
            generationSlotWaiters.removeFirst().resume()
        }
    }

    // MARK: - Import Scan

    /// Line-level scan for `import Module[.Submodule]` in generated interface
    /// text. Machine-generated interfaces spell imports one per line
    /// (optionally attributed, e.g. `@_exported import ObjectiveC`), so no
    /// syntax parsing is needed here.
    static func importedModuleNames(inInterfaceSourceText sourceText: String) -> [String] {
        var importedModuleNames: [String] = []
        var seenModuleNames: Set<String> = []
        sourceText.enumerateLines { line, _ in
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.hasPrefix("//") else { return }
            let tokens = trimmedLine.split(separator: " ")
            guard let importTokenIndex = tokens.firstIndex(of: "import"), importTokenIndex + 1 < tokens.count else { return }
            // Reject lines where `import` is not a keyword at clause start
            // (every leading token of a real import is an attribute/modifier).
            let leadingTokens = tokens[..<importTokenIndex]
            guard leadingTokens.allSatisfy({ $0.hasPrefix("@") || $0 == "public" || $0 == "internal" }) else { return }
            let importedModuleName = String(tokens[importTokenIndex + 1])
            guard seenModuleNames.insert(importedModuleName).inserted else { return }
            importedModuleNames.append(importedModuleName)
        }
        return importedModuleNames
    }
}

/// The two requests ``SourceKitManager`` sends for an interface: open it under
/// a document name, and close that document again. A protocol so that tests
/// can check the pairing and the concurrency without sourcekitd.
@available(macOS 13.0, *)
protocol InterfaceDocumentService: Sendable {
    /// Opens `moduleName`'s interface as the document `documentName` and
    /// returns it converted to plain values.
    func openInterface(documentName: String, moduleName: String, compilerArguments: [String]) async throws -> SourceKitManager.GeneratedModuleInterface

    /// Closes the document `documentName`, releasing what SourceKitService
    /// holds for it. Closing a name that was never opened does nothing.
    func closeInterface(documentName: String) async throws
}

/// ``InterfaceDocumentService`` over sourcekitd: `editor.open.interface` and
/// `editor.close`.
@available(macOS 13.0, *)
actor SourceKitDInterfaceDocumentService: InterfaceDocumentService {
    private var cachedSourceKitD: SourceKitD?

    init() {}

    private func sourcekitd() async throws -> SourceKitD {
        if let cachedSourceKitD {
            return cachedSourceKitD
        }
        // Derived from the active developer directory rather than hardcoding
        // /Applications/Xcode.app, so Xcode-beta, multi-Xcode and Command
        // Line Tools setups work.
        guard let sourcekitdPath = SourceKitLocator.activeSourceKitPath() else {
            throw SourceKitManager.Error.sourceKitNotFound
        }
        let sourceKitD = try await SourceKitD.getOrCreate(dylibPath: URL(fileURLWithPath: sourcekitdPath), pluginPaths: nil)
        cachedSourceKitD = sourceKitD
        return sourceKitD
    }

    func openInterface(documentName: String, moduleName: String, compilerArguments: [String]) async throws -> SourceKitManager.GeneratedModuleInterface {
        let sourcekitd = try await sourcekitd()
        let keys = sourcekitd.keys
        let request = sourcekitd.dictionary([
            keys.moduleName: moduleName,
            keys.name: documentName,
            keys.enableStructure: 1,
            keys.compilerArgs: compilerArguments as [any SKDRequestValue],
        ])
        let response = try await sourcekitd.send(
            \.editorOpenInterface,
            request,
            timeout: .seconds(120),
            restartTimeout: .seconds(120),
            documentUrl: nil,
            fileContents: nil
        )
        guard let sourceText: String = response[keys.sourceText] else {
            throw SourceKitManager.Error.missingSourceText(moduleName: moduleName)
        }
        guard let substructure: SKDResponseArray = response[keys.subStructure] else {
            throw SourceKitManager.Error.missingSubstructure(moduleName: moduleName)
        }
        return SourceKitManager.GeneratedModuleInterface(
            moduleName: moduleName,
            sourceText: sourceText,
            declarations: Self.declarationNodes(of: substructure, in: sourcekitd),
            importedModuleNames: SourceKitManager.importedModuleNames(inInterfaceSourceText: sourceText)
        )
    }

    func closeInterface(documentName: String) async throws {
        let sourcekitd = try await sourcekitd()
        let request = sourcekitd.dictionary([
            sourcekitd.keys.name: documentName,
        ])
        _ = try await sourcekitd.send(
            \.editorClose,
            request,
            timeout: .seconds(30),
            restartTimeout: .seconds(120),
            documentUrl: nil,
            fileContents: nil
        )
    }

    // MARK: - Response Conversion

    private static func declarationNodes(of substructure: SKDResponseArray, in sourcekitd: SourceKitD) -> [InterfaceDeclarationNode] {
        var nodes: [InterfaceDeclarationNode] = []
        substructure.forEach { _, nodeDictionary in
            let keys = sourcekitd.keys
            let kindUID: sourcekitd_api_uid_t? = nodeDictionary[keys.kind]
            let kindUIDString = kindUID.flatMap { uid in
                sourcekitd.api.uid_get_string_ptr(uid).map { String(cString: $0) }
            }
            let kind = kindUIDString.map { InterfaceDeclarationNode.kind(forUIDString: $0) } ?? .other
            let name: String? = nodeDictionary[keys.name]
            // `other` nodes are never descended into by the extractor, so
            // their subtrees are dropped here to keep the value tree small.
            let children: [InterfaceDeclarationNode]
            if kind != .other, let childSubstructure: SKDResponseArray = nodeDictionary[keys.subStructure] {
                children = declarationNodes(of: childSubstructure, in: sourcekitd)
            } else {
                children = []
            }
            nodes.append(InterfaceDeclarationNode(kind: kind, name: name, children: children))
            return true
        }
        return nodes
    }
}

// Protocol-form `@Loggable` — see the note in SDKIndexer.swift: the direct
// type form clashes with the `@available(macOS 13.0, *)` scope.
@Loggable(.fileprivate, subsystem: "com.mxiris.type-indexing", category: "SourceKitManager")
fileprivate protocol SourceKitManagerLogging {}

@available(macOS 13.0, *)
extension SourceKitManager: SourceKitManagerLogging {}

#endif
