#if os(macOS)

import Foundation
import Testing
@testable import TypeIndexing

/// The runtime-metadata layer of `TypeDatabase`: dependency images registered
/// as `DeclaredTypeNameSource`s, read lazily and only on a miss of API notes
/// and module interfaces.
@Suite
struct DeclaredTypeNameSourceTests {
    /// Records how often it was read, and answers with a fixed list or an
    /// error.
    private final class RecordingSource: DeclaredTypeNameSource, @unchecked Sendable {
        let imagePath: String
        private let result: Result<[String], any Error>
        private let lock = NSLock()
        private var storedReadCount = 0

        init(imagePath: String, declaredTypeNames: [String]) {
            self.imagePath = imagePath
            self.result = .success(declaredTypeNames)
        }

        init(imagePath: String, failure: any Error) {
            self.imagePath = imagePath
            self.result = .failure(failure)
        }

        var readCount: Int {
            lock.withLock { storedReadCount }
        }

        func declaredTypeNames() async throws -> [String] {
            lock.withLock { storedReadCount += 1 }
            return try result.get()
        }
    }

    private struct UnreadableImage: Error {}

    @Test
    func declaredTypeNameSourcesAreQueriedLazilyInDependencyOrder() async {
        let firstSource = RecordingSource(imagePath: "/System/Library/PrivateFrameworks/First.framework/First", declaredTypeNames: ["_FirstPrivate"])
        let secondSource = RecordingSource(imagePath: "/System/Library/PrivateFrameworks/Second.framework/Second", declaredTypeNames: ["_SecondPrivate"])
        let typeDatabase = TypeDatabase(platform: .macOS)
        await typeDatabase.register(dependencies: [firstSource, secondSource])

        #expect(firstSource.readCount == 0)
        #expect(await typeDatabase.moduleName(forTypeName: "_FirstPrivate") == "First")
        #expect(firstSource.readCount == 1)
        #expect(secondSource.readCount == 0)

        #expect(await typeDatabase.moduleName(forTypeName: "_SecondPrivate") == "Second")
        #expect(secondSource.readCount == 1)

        #expect(await typeDatabase.moduleName(forTypeName: "_FirstPrivate") == "First")
        #expect(firstSource.readCount == 1)
    }

    @Test
    func firstImageDeclaringANameWinsTheAttribution() async {
        let earlierSource = RecordingSource(imagePath: "/usr/lib/libEarlier.dylib", declaredTypeNames: ["Shared"])
        let laterSource = RecordingSource(imagePath: "/usr/lib/libLater.dylib", declaredTypeNames: ["Shared", "OnlyLater"])
        let typeDatabase = TypeDatabase(platform: .macOS)
        await typeDatabase.register(dependencies: [earlierSource, laterSource])

        #expect(await typeDatabase.moduleName(forTypeName: "OnlyLater") == "libLater")
        #expect(await typeDatabase.moduleName(forTypeName: "Shared") == "libEarlier")
    }

    @Test
    func failingSourceIsDroppedAndNotRetried() async {
        let failingSource = RecordingSource(imagePath: "/usr/lib/libBroken.dylib", failure: UnreadableImage())
        let workingSource = RecordingSource(imagePath: "/usr/lib/libWorking.dylib", declaredTypeNames: ["Working"])
        let typeDatabase = TypeDatabase(platform: .macOS)
        await typeDatabase.register(dependencies: [failingSource, workingSource])

        #expect(await typeDatabase.moduleName(forTypeName: "Missing") == nil)
        #expect(await typeDatabase.moduleName(forTypeName: "Missing") == nil)
        #expect(await typeDatabase.moduleName(forTypeName: "Working") == "libWorking")
        #expect(failingSource.readCount == 1)
        #expect(workingSource.readCount == 1)
    }

    @Test
    func repeatedDependencyRegistrationAddsNothing() async {
        let source = RecordingSource(imagePath: "/usr/lib/libOnce.dylib", declaredTypeNames: ["Once"])
        let sameImageAgain = RecordingSource(imagePath: "/usr/lib/libOnce.dylib", declaredTypeNames: ["Again"])
        let typeDatabase = TypeDatabase(platform: .macOS)
        await typeDatabase.register(dependencies: [source])
        await typeDatabase.register(dependencies: [sameImageAgain])

        #expect(await typeDatabase.moduleName(forTypeName: "Again") == nil)
        #expect(sameImageAgain.readCount == 0)
    }

    /// API notes, module interfaces and runtime metadata are consulted in that
    /// order whatever order they were registered in: a later
    /// `index(dependencies:moduleFilter:)` call adds interface names after the
    /// SDK's API notes, and must not take a name back from them.
    @Test
    func apiNotesOutrankInterfaceNamesRegisteredLater() async throws {
        let temporaryFileURL = FileManager.default.temporaryDirectory
            .appending(component: "DeclaredTypeNameSourceTests-\(UUID().uuidString).apinotes")
        try """
        Name: RightModule
        Classes:
        - Name: TSTThing
        """.write(to: temporaryFileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temporaryFileURL) }

        let runtimeSource = RecordingSource(imagePath: "/usr/lib/libRuntime.dylib", declaredTypeNames: ["TSTThing", "TSTInterfaceThing"])
        let typeDatabase = TypeDatabase(platform: .macOS)
        await typeDatabase.register(dependencies: [runtimeSource])
        await typeDatabase.register(apiNotesIndex: APINotesIndex(files: [try APINotesFile(path: temporaryFileURL.path(percentEncoded: false))]))
        await typeDatabase.register(moduleEntries: [
            ModuleIndexCacheEntry(moduleName: "WrongModule", typeNames: ["TSTThing", "TSTInterfaceThing"], subModuleNames: []),
        ])

        #expect(await typeDatabase.moduleName(forTypeName: "TSTThing") == "RightModule")
        #expect(await typeDatabase.moduleName(forTypeName: "TSTInterfaceThing") == "WrongModule")
        #expect(runtimeSource.readCount == 0)
    }
}

#endif
