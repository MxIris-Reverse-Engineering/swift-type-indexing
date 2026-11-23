#if os(macOS)

import Foundation
import Testing
@testable import TypeIndexing

/// The Swift name an API notes entry gives a C declaration, as the Clang
/// importer computes it (`swift/lib/ClangImporter/ImportName.cpp`): a
/// `SwiftName` is used as is and returns before `swift_private` is looked at;
/// only without one does `SwiftPrivate: true` prefix `__` to the C name.
///
/// UIKit's `UICellConfigurationState` is the first case (`SwiftPrivate: true`,
/// imported as `__UICellConfigurationState`); PencilKit's `PKDrawing` is the
/// second (`SwiftName: PKDrawingReference`).
@Suite
struct SwiftNameRuleTests {
    private static let apiNotesYAML = """
    Name: TestModule
    Classes:
    - Name: TSTHiddenClass
      SwiftPrivate: true
    - Name: TSTRenamedAndHidden
      SwiftName: RenamedAndHidden
      SwiftPrivate: true
    - Name: TSTPlainClass
    Protocols:
    - Name: TSTHiddenProtocol
      SwiftPrivate: true
    Tags:
    - Name: TSTHiddenTag
      SwiftPrivate: true
    Typedefs:
    - Name: TSTHiddenTypedef
      SwiftPrivate: true
    Enumerators:
    - Name: kTSTHiddenValue
      SwiftPrivate: true
    """

    private static func makeIndex() throws -> APINotesIndex {
        let temporaryFileURL = FileManager.default.temporaryDirectory
            .appending(component: "SwiftNameRuleTests-\(UUID().uuidString).apinotes")
        try apiNotesYAML.write(to: temporaryFileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temporaryFileURL) }
        return APINotesIndex(files: [try APINotesFile(path: temporaryFileURL.path(percentEncoded: false))])
    }

    @Test
    func swiftPrivateWithoutSwiftNameResolvesToDoubleUnderscorePrefix() throws {
        let index = try Self.makeIndex()
        #expect(index.swiftName(forCName: "TSTHiddenClass", category: .objcClass)?.name == "__TSTHiddenClass")
        #expect(index.swiftName(forCName: "TSTHiddenProtocol", category: .objcProtocol)?.name == "__TSTHiddenProtocol")
        #expect(index.swiftName(forCName: "TSTHiddenTag", category: .valueType)?.name == "__TSTHiddenTag")
        #expect(index.swiftName(forCName: "TSTHiddenTypedef", category: .other)?.name == "__TSTHiddenTypedef")
        #expect(index.cName(forSwiftName: "__TSTHiddenClass")?.name == "TSTHiddenClass")
        #expect(index.swiftName(forCName: "TSTHiddenClass", category: .objcClass)?.moduleName == "TestModule")
    }

    @Test
    func swiftNameWinsOverSwiftPrivate() throws {
        let index = try Self.makeIndex()
        #expect(index.swiftName(forCName: "TSTRenamedAndHidden", category: .objcClass)?.name == "RenamedAndHidden")
        #expect(index.cName(forSwiftName: "RenamedAndHidden")?.name == "TSTRenamedAndHidden")
    }

    @Test
    func plainEntityKeepsItsCName() throws {
        let index = try Self.makeIndex()
        #expect(index.swiftName(forCName: "TSTPlainClass", category: .objcClass) == nil)
    }

    /// An enumerator is not a type: its `__` placement follows enum-case
    /// rules the type-name tables have no use for, so it stays out of them.
    @Test
    func swiftPrivateEnumeratorIsNotRenamed() throws {
        let index = try Self.makeIndex()
        #expect(index.swiftName(forCName: "kTSTHiddenValue", category: .valueType) == nil)
        #expect(index.moduleName(forCName: "kTSTHiddenValue") == "TestModule")
    }

    @Test
    func typeDatabaseResolvesSwiftPrivateTypeNames() async throws {
        let typeDatabase = TypeDatabase(platform: .macOS)
        await typeDatabase.register(apiNotesIndex: try Self.makeIndex())
        #expect(await typeDatabase.swiftName(forCName: "TSTHiddenClass", category: .objcClass) == "__TSTHiddenClass")
        #expect(await typeDatabase.moduleName(forTypeName: "TSTHiddenClass") == "TestModule")
        #expect(await typeDatabase.moduleName(forTypeName: "__TSTHiddenClass") == "TestModule")
    }
}

#endif
