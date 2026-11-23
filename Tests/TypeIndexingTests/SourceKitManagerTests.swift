#if os(macOS)

import Foundation
import Testing
@testable import TypeIndexing

/// How `SourceKitManager` treats SourceKitService's interface documents, driven
/// through a stand-in for sourcekitd: every interface it opens it closes again
/// under the same name, and only a few are generated at once.
///
/// Before either held, SourceKitService kept a context of about 1 GB for every
/// module it had generated, and every module an image links was requested at
/// once: indexing AppKit's dependencies took it to 27 GB in six seconds.
@Suite
struct SourceKitManagerTests {
    private static let sdkSettings = SDKSettings(sdkPath: "/nonexistent-sdk", version: "0.0", productBuildVersion: nil)

    enum StubError: Error {
        case generationFailed
    }

    /// Records the document names it is asked to open and close, and the most
    /// generations that were running at the same time.
    private final class RecordingDocumentService: InterfaceDocumentService, @unchecked Sendable {
        struct Record {
            var openedDocumentNames: [String] = []
            var closedDocumentNames: [String] = []
            var runningGenerationCount = 0
            var mostRunningGenerations = 0
        }

        private let lock = NSLock()
        private var currentRecord = Record()
        private let failingModuleNames: Set<String>
        private let generationDuration: Duration

        init(failingModuleNames: Set<String> = [], generationDuration: Duration = .zero) {
            self.failingModuleNames = failingModuleNames
            self.generationDuration = generationDuration
        }

        var record: Record {
            lock.withLock { currentRecord }
        }

        func openInterface(documentName: String, moduleName: String, compilerArguments: [String]) async throws -> SourceKitManager.GeneratedModuleInterface {
            lock.withLock {
                currentRecord.openedDocumentNames.append(documentName)
                currentRecord.runningGenerationCount += 1
                currentRecord.mostRunningGenerations = max(currentRecord.mostRunningGenerations, currentRecord.runningGenerationCount)
            }
            defer {
                lock.withLock { currentRecord.runningGenerationCount -= 1 }
            }
            try await Task.sleep(for: generationDuration)
            if failingModuleNames.contains(moduleName) {
                throw StubError.generationFailed
            }
            return SourceKitManager.GeneratedModuleInterface(moduleName: moduleName, sourceText: "", declarations: [], importedModuleNames: [])
        }

        func closeInterface(documentName: String) async throws {
            lock.withLock { currentRecord.closedDocumentNames.append(documentName) }
        }
    }

    @Test("every interface it opens is closed again under its own name, also when its generation fails")
    func everyOpenedInterfaceIsClosed() async throws {
        let documentService = RecordingDocumentService(failingModuleNames: ["Broken"])
        let sourceKitManager = SourceKitManager(documentService: documentService)

        for moduleName in ["AppKit", "Foundation"] {
            let interface = try await sourceKitManager.interface(for: moduleName, platform: .macOS, sdkSettings: Self.sdkSettings)
            #expect(interface.moduleName == moduleName)
        }
        await #expect(throws: StubError.self) {
            try await sourceKitManager.interface(for: "Broken", platform: .macOS, sdkSettings: Self.sdkSettings)
        }

        let record = documentService.record
        #expect(record.openedDocumentNames.count == 3)
        #expect(Set(record.openedDocumentNames).count == 3, "each interface gets a document of its own")
        #expect(record.closedDocumentNames == record.openedDocumentNames)
    }

    @Test("no more interfaces are generated at once than the limit allows, and all of them are closed")
    func generationsInFlightStayWithinTheLimit() async throws {
        let documentService = RecordingDocumentService(generationDuration: .milliseconds(50))
        let sourceKitManager = SourceKitManager(documentService: documentService, maximumConcurrentGenerations: 2)
        let moduleNames = (0 ..< 8).map { "Module\($0)" }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for moduleName in moduleNames {
                group.addTask {
                    _ = try await sourceKitManager.interface(for: moduleName, platform: .macOS, sdkSettings: Self.sdkSettings)
                }
            }
            try await group.waitForAll()
        }

        let record = documentService.record
        #expect(record.mostRunningGenerations == 2, "two at a time: never more, and the limit is used")
        #expect(record.openedDocumentNames.count == moduleNames.count)
        #expect(Set(record.closedDocumentNames) == Set(record.openedDocumentNames))
    }

    @Test("by default it generates two interfaces at a time")
    func defaultLimitIsTwo() async {
        #expect(await SourceKitManager().maximumConcurrentGenerations == 2)
    }
}

#endif
