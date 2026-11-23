#if os(macOS)

/// What an API notes file says about how Swift imports one declaration: the
/// two attributes an Objective-C header spells `NS_SWIFT_NAME(...)` and
/// `NS_REFINED_FOR_SWIFT`.
public struct SwiftImportAnnotation: Sendable, Hashable {
    /// `SwiftName:` — the Swift name as written, for a type
    /// (`PKDrawingReference`) or a member (`init(strokes:)`).
    public var swiftName: String?

    /// `SwiftPrivate: true`. Without a ``swiftName`` Swift prefixes `__` to
    /// the declaration's name.
    public var isSwiftPrivate: Bool

    public init(swiftName: String?, isSwiftPrivate: Bool) {
        self.swiftName = swiftName
        self.isSwiftPrivate = isSwiftPrivate
    }
}

/// The key an API notes file gives an Objective-C member.
public enum ObjCMemberKey: Sendable, Hashable {
    /// A method or initializer by its selector (`initWithData:error:`).
    case method(selector: String, isClassMethod: Bool)
    /// A property by the name its `@property` declares.
    case property(name: String, isClassProperty: Bool)
}

/// What API notes say about one Objective-C class or protocol and its
/// members. Only declarations that carry a `SwiftName` or `SwiftPrivate` are
/// listed.
public struct ObjCContainerSwiftImportAnnotations: Sendable, Hashable {
    /// The class or protocol itself.
    public var declaration: SwiftImportAnnotation?

    /// Its methods and properties.
    public var members: [ObjCMemberKey: SwiftImportAnnotation]

    public init(declaration: SwiftImportAnnotation? = nil, members: [ObjCMemberKey: SwiftImportAnnotation] = [:]) {
        self.declaration = declaration
        self.members = members
    }

    /// Whether there is nothing to mark.
    public var isEmpty: Bool {
        declaration == nil && members.isEmpty
    }
}

#endif
