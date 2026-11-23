#if os(macOS)

/// A dependency image whose runtime metadata lists the types it declares.
///
/// ``TypeDatabase`` consults these only for names that neither the SDK's
/// module interfaces nor its API notes attribute — typically private
/// Objective-C classes such as `_UINavigationBarVisualProvider`. It asks one
/// source at a time, in the order they were registered, and stops at the
/// first image that declares the name: an image listed earlier in dependency
/// order owns a name that several images declare.
///
/// MachOObjCSection implements this over the Objective-C metadata of a Mach-O
/// image; this package itself reads no Mach-O file.
public protocol DeclaredTypeNameSource: Sendable {
    /// The image's install path. The module a name is attributed to is
    /// derived from it (``TypeDatabase/moduleName(forImagePath:)``).
    var imagePath: String { get }

    /// Every class, protocol, struct and union name the image's metadata
    /// declares. A source that throws is skipped and never asked again.
    func declaredTypeNames() async throws -> [String]
}

#endif
