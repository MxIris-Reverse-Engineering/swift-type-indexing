#if os(macOS)

import Foundation
import FoundationToolbox

/// A platform version as an `@_originallyDefinedIn` attribute or an SDK
/// spells it: dotted numeric components, compared numerically, with missing
/// components reading as zero — so `15` equals `15.0` and `15.10` is later
/// than `15.2`.
@available(macOS 13.0, *)
struct PlatformVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The components without trailing zeros, which is what makes `15` and
    /// `15.0` the same value.
    let components: [Int]

    init(components: [Int]) {
        var normalizedComponents = components
        while normalizedComponents.last == 0 {
            normalizedComponents.removeLast()
        }
        self.components = normalizedComponents
    }

    /// Parses `10`, `15.0` or `18.2.1`; nil for anything else.
    init?(_ text: some StringProtocol) {
        var parsedComponents: [Int] = []
        for componentText in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard let component = Int(componentText), component >= 0 else { return nil }
            parsedComponents.append(component)
        }
        guard !parsedComponents.isEmpty else { return nil }
        self.init(components: parsedComponents)
    }

    init(_ operatingSystemVersion: OperatingSystemVersion) {
        self.init(components: [operatingSystemVersion.majorVersion, operatingSystemVersion.minorVersion, operatingSystemVersion.patchVersion])
    }

    static func < (left: PlatformVersion, right: PlatformVersion) -> Bool {
        let componentCount = max(left.components.count, right.components.count)
        for componentIndex in 0 ..< componentCount {
            let leftComponent = componentIndex < left.components.count ? left.components[componentIndex] : 0
            let rightComponent = componentIndex < right.components.count ? right.components[componentIndex] : 0
            if leftComponent != rightComponent {
                return leftComponent < rightComponent
            }
        }
        return false
    }

    var description: String {
        components.isEmpty ? "0" : components.map(String.init).joined(separator: ".")
    }
}

/// The key a moved type is looked up by: the module its mangling names and
/// its top-level name.
@available(macOS 13.0, *)
struct MovedTypeKey: Hashable, Sendable {
    let originalModuleName: String
    let typeName: String
}

/// A top-level type an SDK module declares under
/// `@_originallyDefinedIn(module: "Original", <platform> <version>)`: the
/// compiler mangles it, and every type nested in it, under `Original`, while
/// the module's own interface declares it.
@available(macOS 13.0, *)
struct MovedTypeDeclaration: Hashable, Sendable {
    let typeName: String

    /// The module the mangling names: the attribute's module argument, or
    /// the part of it before a `;` (`"Swift;CompatibilitySpan"` mangles as
    /// `Swift` and links against `CompatibilitySpan`).
    let originalModuleName: String

    /// The module whose interface declares the type now.
    let declaringModuleName: String

    /// The version each platform the attribute names moved the type in,
    /// keyed by the canonical platform name (`macOS`, `macCatalyst`, `iOS`,
    /// `tvOS`, `watchOS`, `visionOS`, `driverKit`).
    let movedVersionsByPlatformName: [String: PlatformVersion]

    var key: MovedTypeKey {
        MovedTypeKey(originalModuleName: originalModuleName, typeName: typeName)
    }

    /// The version `platform` moved the type in, or nil when no attribute
    /// applies to it — the attribute is then inactive there, and the mangling
    /// names the declaring module already.
    ///
    /// The compiler's platform inheritance decides which attributes apply
    /// (`isPlatformActiveForTarget` in the Swift compiler's
    /// `lib/AST/PlatformKindUtils.cpp`): an `iOS` attribute is active on Mac
    /// Catalyst, whose versions follow iOS's, and on visionOS, whose versions
    /// are mapped from it.
    func movedVersion(on platform: SDKPlatform) -> PlatformVersion? {
        switch platform {
        case .macOS:
            return movedVersionsByPlatformName["macOS"]
        case .macCatalyst:
            return movedVersionsByPlatformName["macCatalyst"] ?? movedVersionsByPlatformName["iOS"]
        case .iOS, .iOSSimulator:
            return movedVersionsByPlatformName["iOS"]
        case .tvOS, .tvOSSimulator:
            return movedVersionsByPlatformName["tvOS"]
        case .watchOS, .watchOSSimulator:
            return movedVersionsByPlatformName["watchOS"]
        case .visionOS, .visionOSSimulator:
            if let visionOSVersion = movedVersionsByPlatformName["visionOS"] {
                return visionOSVersion
            }
            return movedVersionsByPlatformName["iOS"].map(Self.visionOSVersion(forIOSVersion:))
        case .driverKit:
            return movedVersionsByPlatformName["driverKit"]
        }
    }

    /// The visionOS version an iOS version corresponds to: iOS 17 is
    /// visionOS 1, iOS 18 is visionOS 2, and from 26 on the two share their
    /// numbers. A move before iOS 17 happened before visionOS existed, so it
    /// is in effect on every visionOS.
    static func visionOSVersion(forIOSVersion iOSVersion: PlatformVersion) -> PlatformVersion {
        guard let majorVersion = iOSVersion.components.first, majorVersion >= 17 else {
            return PlatformVersion(components: [])
        }
        guard majorVersion < 26 else {
            return iOSVersion
        }
        return PlatformVersion(components: [majorVersion - 16] + iOSVersion.components.dropFirst())
    }
}

/// Reads the `@_originallyDefinedIn` moves out of an SDK's textual module
/// interfaces.
///
/// The attribute carries the one fact a binary cannot: its mangled names keep
/// the module a type was originally defined in (`CoreGraphics.CGFloat`), so
/// only the interface of the module that declares it now (CoreFoundation's)
/// says where it went. sourcekitd's generated interfaces keep no attributes,
/// and cover only the modules a binary links, so the textual
/// `.swiftinterface` of every SDK module is scanned instead — a text scan,
/// with no compiler involved.
///
/// The compiler prints an interface one attribute per line, and only
/// top-level declarations carry this one, so the scan reads column-0 lines
/// only: a run of attribute lines, then the declaration they precede.
@available(macOS 13.0, *)
enum MovedTypeIndex {
    /// The moves the SDK modules in `modules` declare, read from each
    /// module's textual interface for `platform`, in `modules` order. A
    /// module without a textual interface contributes nothing; one whose
    /// interface cannot be read is logged and skipped.
    static func movedTypeDeclarations(inModules modules: [SwiftModuleDescriptor], platform: SDKPlatform) -> [MovedTypeDeclaration] {
        var movedTypeDeclarations: [MovedTypeDeclaration] = []
        for module in modules {
            guard let interfaceURL = textualInterfaceURL(inModuleAt: URL(fileURLWithPath: module.path), platform: platform) else { continue }
            let interfaceText: String
            do {
                interfaceText = try String(contentsOf: interfaceURL, encoding: .utf8)
            } catch {
                #log(.error, "Skipping unreadable module interface at \(interfaceURL.path(percentEncoded: false), privacy: .public): \(String(describing: error), privacy: .public)")
                continue
            }
            movedTypeDeclarations.append(contentsOf: Self.movedTypeDeclarations(inInterfaceText: interfaceText, moduleName: module.moduleName))
        }
        #log(.info, "\(movedTypeDeclarations.count) moved types in \(modules.count) \(platform.rawValue, privacy: .public) modules")
        return movedTypeDeclarations
    }

    /// The textual interface of the `.swiftmodule` directory at `moduleURL`
    /// for `platform` (`arm64e-apple-macos.swiftinterface`), never a private
    /// or package one. Of several architectures the first by file name is
    /// taken: the attribute names every platform's version, so all agree.
    static func textualInterfaceURL(inModuleAt moduleURL: URL, platform: SDKPlatform) -> URL? {
        guard let entryURLs = try? FileManager.default.contentsOfDirectory(at: moduleURL, includingPropertiesForKeys: nil) else {
            return nil
        }
        let fileNameSuffix = "-apple-\(platform.textualInterfaceTargetSuffix).swiftinterface"
        return entryURLs
            .filter { $0.lastPathComponent.hasSuffix(fileNameSuffix) }
            .min { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The type declarations `interfaceText`, the textual interface of
    /// `moduleName`, marks as moved from another module.
    static func movedTypeDeclarations(inInterfaceText interfaceText: String, moduleName: String) -> [MovedTypeDeclaration] {
        guard interfaceText.contains("@_originallyDefinedIn") else { return [] }
        var movedTypeDeclarations: [MovedTypeDeclaration] = []
        // Per original module, per platform: the attributes of the run of
        // attribute lines read so far.
        var pendingMovedVersions: [String: [String: PlatformVersion]] = [:]

        for line in interfaceText.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let firstCharacter = line.first else { continue }
            if firstCharacter.isWhitespace {
                // A member, or a continuation of something else: the
                // attributes read so far precede no top-level declaration.
                if !line.allSatisfy(\.isWhitespace) {
                    pendingMovedVersions.removeAll()
                }
                continue
            }
            if line.hasPrefix("//") {
                continue
            }
            if firstCharacter == "#" {
                // `#if compiler(…)` / `#else` / `#endif` delimit alternatives,
                // each with its own attributes.
                pendingMovedVersions.removeAll()
                continue
            }

            let (attributes, remainder) = splitLeadingAttributes(of: line)
            for attribute in attributes {
                guard let (originalModuleName, movedVersions) = parseOriginallyDefinedIn(attribute) else { continue }
                pendingMovedVersions[originalModuleName, default: [:]].merge(movedVersions) { first, _ in first }
            }
            if remainder.isEmpty {
                continue
            }

            if !pendingMovedVersions.isEmpty, let typeName = declaredTypeName(in: remainder) {
                for (originalModuleName, movedVersions) in pendingMovedVersions.sorted(by: { $0.key < $1.key }) where originalModuleName != moduleName {
                    movedTypeDeclarations.append(MovedTypeDeclaration(
                        typeName: typeName,
                        originalModuleName: originalModuleName,
                        declaringModuleName: moduleName,
                        movedVersionsByPlatformName: movedVersions
                    ))
                }
            }
            pendingMovedVersions.removeAll()
        }
        return movedTypeDeclarations
    }

    // MARK: - Line scanning

    /// The attributes a line starts with (each `@name` with its
    /// parenthesized arguments, string literals inside them respected) and
    /// what follows them, trimmed.
    static func splitLeadingAttributes(of line: Substring) -> (attributes: [Substring], remainder: Substring) {
        var attributes: [Substring] = []
        var currentIndex = line.startIndex
        while true {
            while currentIndex < line.endIndex, line[currentIndex].isWhitespace {
                currentIndex = line.index(after: currentIndex)
            }
            guard currentIndex < line.endIndex, line[currentIndex] == "@" else { break }
            let attributeStartIndex = currentIndex
            currentIndex = line.index(after: currentIndex)
            // A qualified attribute name (`@_Concurrency.MainActor`,
            // `@Swift::Sendable`) is one name.
            while currentIndex < line.endIndex, line[currentIndex].isLetter || line[currentIndex].isNumber || "_.:".contains(line[currentIndex]) {
                currentIndex = line.index(after: currentIndex)
            }
            if currentIndex < line.endIndex, line[currentIndex] == "(" {
                currentIndex = indexAfterBalancedParentheses(in: line, startingAt: currentIndex)
            }
            attributes.append(line[attributeStartIndex ..< currentIndex])
        }
        return (attributes, trimmed(line[currentIndex...]))
    }

    /// The index just past the parenthesis that closes the one at
    /// `openingIndex`, or the end of the line when it never closes.
    private static func indexAfterBalancedParentheses(in line: Substring, startingAt openingIndex: Substring.Index) -> Substring.Index {
        var depth = 0
        var isInsideStringLiteral = false
        var currentIndex = openingIndex
        while currentIndex < line.endIndex {
            let character = line[currentIndex]
            if isInsideStringLiteral {
                if character == "\\" {
                    currentIndex = line.index(after: currentIndex)
                    if currentIndex == line.endIndex { break }
                } else if character == "\"" {
                    isInsideStringLiteral = false
                }
            } else if character == "\"" {
                isInsideStringLiteral = true
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return line.index(after: currentIndex)
                }
            }
            currentIndex = line.index(after: currentIndex)
        }
        return line.endIndex
    }

    private static func trimmed(_ text: Substring) -> Substring {
        guard let firstIndex = text.firstIndex(where: { !$0.isWhitespace }),
              let lastIndex = text.lastIndex(where: { !$0.isWhitespace })
        else {
            return text[text.endIndex...]
        }
        return text[firstIndex ... lastIndex]
    }

    /// The original module and the per-platform versions of an
    /// `@_originallyDefinedIn(module: "M", macOS 15.0, iOS 18.0)` attribute;
    /// nil for any other attribute.
    static func parseOriginallyDefinedIn(_ attribute: Substring) -> (originalModuleName: String, movedVersions: [String: PlatformVersion])? {
        let attributeNamePrefix = "@_originallyDefinedIn("
        guard attribute.hasPrefix(attributeNamePrefix), attribute.hasSuffix(")") else { return nil }
        let arguments = attribute.dropFirst(attributeNamePrefix.count).dropLast()
        guard let moduleLabelRange = arguments.range(of: "module:") else { return nil }
        let afterModuleLabel = arguments[moduleLabelRange.upperBound...].drop { $0.isWhitespace }
        guard afterModuleLabel.first == "\"" else { return nil }
        let moduleArgumentStart = afterModuleLabel.index(after: afterModuleLabel.startIndex)
        guard let moduleArgumentEnd = afterModuleLabel[moduleArgumentStart...].firstIndex(of: "\"") else { return nil }
        let moduleArgument = afterModuleLabel[moduleArgumentStart ..< moduleArgumentEnd]
        let originalModuleName = String(moduleArgument.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? moduleArgument)
        guard !originalModuleName.isEmpty else { return nil }

        var movedVersions: [String: PlatformVersion] = [:]
        let platformArguments = afterModuleLabel[afterModuleLabel.index(after: moduleArgumentEnd)...]
        for platformArgument in platformArguments.split(separator: ",") {
            let platformArgumentWords = platformArgument.split(whereSeparator: \.isWhitespace)
            guard platformArgumentWords.count == 2,
                  let platformName = canonicalPlatformName(platformArgumentWords[0]),
                  let movedVersion = PlatformVersion(platformArgumentWords[1])
            else { continue }
            if movedVersions[platformName] == nil {
                movedVersions[platformName] = movedVersion
            }
        }
        guard !movedVersions.isEmpty else { return nil }
        return (originalModuleName, movedVersions)
    }

    /// The canonical spelling of an availability platform name, an
    /// application-extension platform folded into its base platform; nil
    /// for a platform no SDK of this package covers.
    static func canonicalPlatformName(_ platformName: some StringProtocol) -> String? {
        var lowercasedName = platformName.lowercased()
        let applicationExtensionSuffix = "applicationextension"
        if lowercasedName.hasSuffix(applicationExtensionSuffix) {
            lowercasedName.removeLast(applicationExtensionSuffix.count)
        }
        switch lowercasedName {
        case "macos", "osx":
            return "macOS"
        case "maccatalyst":
            return "macCatalyst"
        case "ios":
            return "iOS"
        case "tvos":
            return "tvOS"
        case "watchos":
            return "watchOS"
        case "visionos", "xros":
            return "visionOS"
        case "driverkit":
            return "driverKit"
        default:
            return nil
        }
    }

    private static let typeDeclarationKeywords: Set<Substring> = ["struct", "class", "enum", "protocol", "actor", "typealias"]

    private static let declarationModifiers: Set<Substring> = [
        "public", "open", "package", "internal", "fileprivate", "private",
        "final", "indirect", "distributed", "nonisolated",
    ]

    /// The name of the type a declaration line declares (`public struct
    /// CGFloat : Swift::Sendable {` declares `CGFloat`), or nil when it
    /// declares something else — an extension, a function, a variable.
    static func declaredTypeName(in declaration: Substring) -> String? {
        let words = declaration.split(whereSeparator: \.isWhitespace)
        var wordIndex = 0
        while wordIndex < words.count, declarationModifiers.contains(words[wordIndex]) || words[wordIndex].hasPrefix("nonisolated(") {
            wordIndex += 1
        }
        guard wordIndex + 1 < words.count, typeDeclarationKeywords.contains(words[wordIndex]) else { return nil }
        let nameWord = words[wordIndex + 1]
        if nameWord.hasPrefix("`") {
            let escapedName = nameWord.dropFirst().prefix { $0 != "`" }
            return escapedName.isEmpty ? nil : String(escapedName)
        }
        let name = nameWord.prefix { !"<:={(".contains($0) }
        return name.isEmpty ? nil : String(name)
    }
}

// Protocol-form `@Loggable`: the direct type form's generated static stored
// logger is rejected inside `@available(macOS 13.0, *)` types at
// emit-module time ("cannot be more available than enclosing scope").
@Loggable(.fileprivate, subsystem: "com.mxiris.type-indexing", category: "MovedTypeIndex")
fileprivate protocol MovedTypeIndexLogging {}

@available(macOS 13.0, *)
extension MovedTypeIndex: MovedTypeIndexLogging {}

#endif
