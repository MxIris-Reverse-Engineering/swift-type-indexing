#if os(macOS)

import Foundation
import Testing
@testable import TypeIndexing

/// What API notes say about how Swift imports an Objective-C class or
/// protocol and its members — the `NS_SWIFT_NAME` / `NS_REFINED_FOR_SWIFT`
/// an Objective-C header printer puts back.
@Suite
struct ObjCSwiftImportAnnotationTests {
    private static func makeIndex(yamls apiNotesYAMLs: [String]) throws -> APINotesIndex {
        var files: [APINotesFile] = []
        for apiNotesYAML in apiNotesYAMLs {
            let temporaryFileURL = FileManager.default.temporaryDirectory
                .appending(component: "ObjCSwiftImportAnnotationTests-\(UUID().uuidString).apinotes")
            try apiNotesYAML.write(to: temporaryFileURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: temporaryFileURL) }
            files.append(try APINotesFile(path: temporaryFileURL.path(percentEncoded: false)))
        }
        return APINotesIndex(files: files)
    }

    private static let drawingYAML = """
    Name: Drawing
    Classes:
    - Name: SMPDrawing
      SwiftName: SMPDrawingReference
      Methods:
      - Selector: 'initWithData:error:'
        MethodKind: Instance
        SwiftPrivate: true
      - Selector: 'drawingWithStrokes:'
        MethodKind: Class
        SwiftName: 'init(strokes:)'
      - Selector: 'plainMethod'
        MethodKind: Instance
      Properties:
      - Name: strokes
        PropertyKind: Instance
        SwiftName: allStrokes
      - Name: sharedDrawing
        SwiftPrivate: true
    - Name: SMPHiddenState
      SwiftPrivate: true
    - Name: SMPListedOnly
    Protocols:
    - Name: SMPDrawing
      SwiftName: SMPDrawingProtocol
      Methods:
      - Selector: 'drawingDidChange:'
        MethodKind: Instance
        SwiftName: 'drawingChanged(_:)'
    """

    @Test
    func classAnnotationCarriesSwiftNameAndSwiftPrivate() throws {
        let index = try Self.makeIndex(yamls: [Self.drawingYAML])
        let drawing = try #require(index.swiftImportAnnotations(forObjCClassNamed: "SMPDrawing"))
        #expect(drawing.declaration == SwiftImportAnnotation(swiftName: "SMPDrawingReference", isSwiftPrivate: false))
        let hiddenState = try #require(index.swiftImportAnnotations(forObjCClassNamed: "SMPHiddenState"))
        #expect(hiddenState.declaration == SwiftImportAnnotation(swiftName: nil, isSwiftPrivate: true))
    }

    @Test
    func methodAnnotationIsKeyedBySelectorAndKind() throws {
        let index = try Self.makeIndex(yamls: [Self.drawingYAML])
        let drawing = try #require(index.swiftImportAnnotations(forObjCClassNamed: "SMPDrawing"))
        #expect(drawing.members[.method(selector: "initWithData:error:", isClassMethod: false)] == SwiftImportAnnotation(swiftName: nil, isSwiftPrivate: true))
        #expect(drawing.members[.method(selector: "drawingWithStrokes:", isClassMethod: true)] == SwiftImportAnnotation(swiftName: "init(strokes:)", isSwiftPrivate: false))
        #expect(drawing.members[.method(selector: "drawingWithStrokes:", isClassMethod: false)] == nil)
        #expect(drawing.members[.method(selector: "plainMethod", isClassMethod: false)] == nil)
    }

    /// A property without `PropertyKind` names both the instance and the
    /// class property, as Clang's API notes compiler reads it.
    @Test
    func propertyAnnotationIsKeyedByNameAndKind() throws {
        let index = try Self.makeIndex(yamls: [Self.drawingYAML])
        let drawing = try #require(index.swiftImportAnnotations(forObjCClassNamed: "SMPDrawing"))
        #expect(drawing.members[.property(name: "strokes", isClassProperty: false)] == SwiftImportAnnotation(swiftName: "allStrokes", isSwiftPrivate: false))
        #expect(drawing.members[.property(name: "strokes", isClassProperty: true)] == nil)
        let hidden = SwiftImportAnnotation(swiftName: nil, isSwiftPrivate: true)
        #expect(drawing.members[.property(name: "sharedDrawing", isClassProperty: false)] == hidden)
        #expect(drawing.members[.property(name: "sharedDrawing", isClassProperty: true)] == hidden)
    }

    @Test
    func protocolAnnotationsAreSeparateFromClassAnnotations() throws {
        let index = try Self.makeIndex(yamls: [Self.drawingYAML])
        let drawingProtocol = try #require(index.swiftImportAnnotations(forObjCProtocolNamed: "SMPDrawing"))
        #expect(drawingProtocol.declaration?.swiftName == "SMPDrawingProtocol")
        #expect(drawingProtocol.members[.method(selector: "drawingDidChange:", isClassMethod: false)]?.swiftName == "drawingChanged(_:)")
        #expect(drawingProtocol.members[.method(selector: "initWithData:error:", isClassMethod: false)] == nil)
        #expect(index.swiftImportAnnotations(forObjCClassNamed: "SMPDrawing")?.declaration?.swiftName == "SMPDrawingReference")
    }

    @Test
    func entryWithoutNamingAnnotationsIsLeftOut() throws {
        let index = try Self.makeIndex(yamls: [Self.drawingYAML])
        #expect(index.swiftImportAnnotations(forObjCClassNamed: "SMPListedOnly") == nil)
        #expect(index.swiftImportAnnotations(forObjCClassNamed: "SMPUnknown") == nil)
    }

    /// Several modules' API notes list `NSObject` to annotate their own
    /// category methods: the members merge, a later file winning per member,
    /// and a listing without a class-level annotation keeps the earlier one.
    @Test
    func listingsMergeAcrossFiles() throws {
        let index = try Self.makeIndex(yamls: [
            """
            Name: Declaring
            Classes:
            - Name: SMPBase
              SwiftName: Base
              Methods:
              - Selector: 'shared'
                MethodKind: Class
                SwiftName: 'makeShared()'
            """,
            """
            Name: Annotating
            Classes:
            - Name: SMPBase
              Methods:
              - Selector: 'shared'
                MethodKind: Class
                SwiftPrivate: true
              - Selector: 'categoryMethod'
                MethodKind: Instance
                SwiftName: 'performCategoryMethod()'
            """,
        ])
        let base = try #require(index.swiftImportAnnotations(forObjCClassNamed: "SMPBase"))
        #expect(base.declaration?.swiftName == "Base")
        #expect(base.members[.method(selector: "shared", isClassMethod: true)] == SwiftImportAnnotation(swiftName: nil, isSwiftPrivate: true))
        #expect(base.members[.method(selector: "categoryMethod", isClassMethod: false)]?.swiftName == "performCategoryMethod()")
    }

    @Test
    func typeDatabaseAnswersForClassesAndProtocols() async throws {
        let typeDatabase = TypeDatabase(platform: .macOS)
        await typeDatabase.register(apiNotesIndex: try Self.makeIndex(yamls: [Self.drawingYAML]))
        #expect(await typeDatabase.swiftImportAnnotations(forObjCClassNamed: "SMPDrawing")?.declaration?.swiftName == "SMPDrawingReference")
        #expect(await typeDatabase.swiftImportAnnotations(forObjCProtocolNamed: "SMPDrawing")?.declaration?.swiftName == "SMPDrawingProtocol")
    }
}

#endif
