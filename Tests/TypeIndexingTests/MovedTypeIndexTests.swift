#if os(macOS)

import Foundation
import Testing
@testable import TypeIndexing

/// The text scan that reads `@_originallyDefinedIn` moves out of a textual
/// module interface, over hand-written interface text — no SDK involved.
@Suite
struct MovedTypeIndexTests {
    private static func version(_ text: String) -> PlatformVersion {
        PlatformVersion(text)!
    }

    /// CoreFoundation's `CGFloat`, as the macOS 27.2 SDK prints it.
    @Test
    func structMovedFromAnotherModuleIsRecorded() {
        let interfaceText = """
        // swift-interface-format-version: 1.0
        @_exported import CoreFoundation
        import Swift
        @available(macOS 10.0, macCatalyst 13.0, iOS 2.0, watchOS 1.0, tvOS 9.0, *)
        @_originallyDefinedIn(module: "CoreGraphics", macOS 10.0)
        @_originallyDefinedIn(module: "CoreGraphics", macCatalyst 13.0)
        @_originallyDefinedIn(module: "CoreGraphics", iOS 2.0)
        @_originallyDefinedIn(module: "CoreGraphics", watchOS 1.0)
        @_originallyDefinedIn(module: "CoreGraphics", tvOS 9.0)
        @frozen public struct CGFloat : Swift::Sendable {
          public typealias NativeType = Swift::Double
        }
        """
        let declarations = MovedTypeIndex.movedTypeDeclarations(inInterfaceText: interfaceText, moduleName: "CoreFoundation")
        #expect(declarations == [
            MovedTypeDeclaration(
                typeName: "CGFloat",
                originalModuleName: "CoreGraphics",
                declaringModuleName: "CoreFoundation",
                movedVersionsByPlatformName: [
                    "macOS": Self.version("10.0"),
                    "macCatalyst": Self.version("13.0"),
                    "iOS": Self.version("2.0"),
                    "watchOS": Self.version("1.0"),
                    "tvOS": Self.version("9.0"),
                ]
            ),
        ])
    }

    @Test
    func protocolClassEnumActorAndTypealiasAreRecorded() {
        let interfaceText = """
        @_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
        public protocol View {
        }
        @_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
        final public class Holder {
        }
        @_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
        public enum Edge : Swift::Int8 {
        }
        @_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
        public actor Worker {
        }
        @_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
        public typealias Body = Swift::Never
        """
        let declarations = MovedTypeIndex.movedTypeDeclarations(inInterfaceText: interfaceText, moduleName: "SwiftUICore")
        #expect(declarations.map(\.typeName) == ["View", "Holder", "Edge", "Worker", "Body"])
        #expect(declarations.allSatisfy { $0.originalModuleName == "SwiftUI" && $0.declaringModuleName == "SwiftUICore" })
    }

    @Test
    func extensionsFunctionsAndVariablesAreNotRecorded() {
        let interfaceText = """
        @_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
        extension SwiftUICore::View {
        }
        @_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
        public func withAnimation<Result>(_ body: () throws -> Result) rethrows -> Result
        @_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
        public var defaultValue: Swift::Int {
          get
        }
        @_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
        public let constant: Swift::Int
        """
        #expect(MovedTypeIndex.movedTypeDeclarations(inInterfaceText: interfaceText, moduleName: "SwiftUICore").isEmpty)
    }

    @Test
    func declarationModifiersAndAttributesBeforeTheKeywordAreSkipped() {
        let interfaceText = """
        @_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
        @frozen @MainActor @preconcurrency public struct Text<Content> : Swift::Sendable where Content : Swift::Hashable {
        }
        @available(*, deprecated, message: "use bar() (not baz) instead")
        @_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
        @_Concurrency.MainActor public final class `Type` {
        }
        @_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
        nonisolated(unsafe) public indirect enum Tree:Swift::Int {
        }
        """
        let declarations = MovedTypeIndex.movedTypeDeclarations(inInterfaceText: interfaceText, moduleName: "SwiftUICore")
        #expect(declarations.map(\.typeName) == ["Text", "Type", "Tree"])
    }

    @Test
    func severalPlatformsInOneAttributeAreSplit() {
        let interfaceText = """
        @_originallyDefinedIn(module: "SwiftUI", macOS 15.0, iOS 18.0, OSXApplicationExtension 15.2)
        @_originallyDefinedIn(module: "SwiftUI", xrOS 2.0)
        public struct Font {
        }
        """
        let declarations = MovedTypeIndex.movedTypeDeclarations(inInterfaceText: interfaceText, moduleName: "SwiftUICore")
        #expect(declarations.first?.movedVersionsByPlatformName == [
            "macOS": Self.version("15.0"),
            "iOS": Self.version("18.0"),
            "visionOS": Self.version("2.0"),
        ])
    }

    @Test
    func manglingModuleIsThePartBeforeTheSemicolon() {
        let interfaceText = """
        @_originallyDefinedIn(module: "_System_Foundation;FoundationEssentials", macOS 26.0)
        public struct Date {
        }
        """
        let declarations = MovedTypeIndex.movedTypeDeclarations(inInterfaceText: interfaceText, moduleName: "Foundation")
        #expect(declarations.map(\.key) == [MovedTypeKey(originalModuleName: "_System_Foundation", typeName: "Date")])
    }

    /// The standard library's `Span` mangles as `Swift` and links against
    /// the back-deployment library: nothing moved between modules.
    @Test
    func moveWithinTheSameModuleIsNotRecorded() {
        let interfaceText = """
        @_originallyDefinedIn(module: "Swift;CompatibilitySpan", macOS 26.0)
        @frozen public struct Span<Element> : Swift::Copyable, ~Swift::Escapable where Element : ~Swift::Copyable {
        }
        """
        #expect(MovedTypeIndex.movedTypeDeclarations(inInterfaceText: interfaceText, moduleName: "Swift").isEmpty)
    }

    @Test
    func indentedAttributesAreIgnored() {
        let interfaceText = """
        public struct Outer {
          @_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
          public struct Inner {
          }
        }
        @_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
          public var interrupting: Swift::Int
        public struct NotMoved {
        }
        """
        #expect(MovedTypeIndex.movedTypeDeclarations(inInterfaceText: interfaceText, moduleName: "SwiftUICore").isEmpty)
    }

    /// Each alternative of a `#if compiler(…)` block carries its own
    /// attributes; the attributes of one never reach the declaration after
    /// the directive.
    @Test
    func conditionalCompilationDirectivesEndTheAttributes() {
        let interfaceText = """
        #if compiler(>=5.3) && $NonescapableTypes
        @_originallyDefinedIn(module: "SwiftUI", macOS 15.0)
        #else
        public struct Unrelated {
        }
        #endif
        """
        #expect(MovedTypeIndex.movedTypeDeclarations(inInterfaceText: interfaceText, moduleName: "SwiftUICore").isEmpty)
    }

    @Test
    func interfaceFileMatchingThePlatformIsChosen() throws {
        let moduleURL = FileManager.default.temporaryDirectory
            .appending(component: "MovedTypeIndexTests-\(UUID().uuidString)")
            .appending(component: "Probe.swiftmodule")
        try FileManager.default.createDirectory(at: moduleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moduleURL.deletingLastPathComponent()) }
        for fileName in [
            "x86_64-apple-macos.swiftinterface",
            "arm64e-apple-macos.swiftinterface",
            "arm64e-apple-macos.private.swiftinterface",
            "arm64e-apple-ios-macabi.swiftinterface",
            "arm64e-apple-macos.swiftdoc",
        ] {
            try Data().write(to: moduleURL.appending(component: fileName))
        }
        #expect(MovedTypeIndex.textualInterfaceURL(inModuleAt: moduleURL, platform: .macOS)?.lastPathComponent == "arm64e-apple-macos.swiftinterface")
        #expect(MovedTypeIndex.textualInterfaceURL(inModuleAt: moduleURL, platform: .macCatalyst)?.lastPathComponent == "arm64e-apple-ios-macabi.swiftinterface")
        #expect(MovedTypeIndex.textualInterfaceURL(inModuleAt: moduleURL, platform: .iOS) == nil)
    }

    @Test
    func versionsCompareNumerically() {
        #expect(Self.version("15") == Self.version("15.0.0"))
        #expect(Self.version("15.2") < Self.version("15.10"))
        #expect(Self.version("26.0") > Self.version("15.2"))
        #expect(PlatformVersion(OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 0)) == Self.version("14.6"))
        #expect(PlatformVersion("15.x") == nil)
    }
}

#endif
