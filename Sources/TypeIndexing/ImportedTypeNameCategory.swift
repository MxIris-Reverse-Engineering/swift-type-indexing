#if os(macOS)

/// The namespace a C-imported name is looked up in.
///
/// A C name is unique only within its kind of declaration: Objective-C
/// declares both a class and a protocol named `NSObject`, and only the
/// protocol is renamed in Swift (`NSObjectProtocol`). A caller resolving a
/// reference says which kind the reference names, so a rename meant for one
/// kind never rewrites another.
public enum ImportedTypeNameCategory: Sendable, Hashable {
    /// An Objective-C class, or a foreign class such as a CF type.
    case objcClass
    /// An Objective-C protocol.
    case objcProtocol
    /// A C struct, union, enum or typedef.
    case valueType
    /// A reference whose kind is not known, such as a typealias.
    case other
}

#endif
