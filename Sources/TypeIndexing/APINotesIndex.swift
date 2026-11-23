#if os(macOS)

import APINotes
import Foundation

/// The name mappings mined from a set of `.apinotes` files: C name ↔ Swift
/// name (for `SwiftName` renames and `SwiftPrivate` types) and C name →
/// declaring module.
///
/// The Swift name follows the Clang importer (`ImportName.cpp`): a
/// `SwiftName` is used as is — the importer returns before it looks at
/// `swift_private` — and only without one does `SwiftPrivate: true` prefix
/// `__` to the C name. UIKit's `UICellConfigurationState` (`SwiftPrivate`)
/// imports as `__UICellConfigurationState`; PencilKit's `PKDrawing`
/// (`SwiftName: PKDrawingReference`) as `PKDrawingReference`.
///
/// Rename tables are split **per declaration category**, because a C name is
/// only unique per category: ObjC declares both a class and a protocol named
/// `NSObject`, and only the protocol carries a `SwiftName` rename
/// (`NSObjectProtocol`) — one merged table rewrote every class reference with
/// the protocol's rename.
///
/// Built once from parsed files and immutable afterwards; the owning
/// `TypeDatabase` actor provides all synchronization.
@available(macOS 13.0, *)
struct APINotesIndex: Sendable {
    struct Name: Sendable, Equatable {
        /// The module whose APINotes file declares the mapping.
        let moduleName: String
        let name: String

        init(moduleName: String, name: String) {
            self.moduleName = moduleName
            self.name = name
        }
    }

    /// C class name → renamed Swift name (`Classes` entries).
    private(set) var classSwiftNamesByCName: [String: Name] = [:]

    /// C protocol name → renamed Swift name (`Protocols` entries, e.g.
    /// `NSObject` → `NSObjectProtocol`).
    private(set) var protocolSwiftNamesByCName: [String: Name] = [:]

    /// C tag / enumerator / typedef name → renamed Swift name, e.g.
    /// `NSActivityOptions` → `ProcessInfo.ActivityOptions`. Enumerators enter
    /// by `SwiftName` only: they are not types, and a `SwiftPrivate`
    /// enumerator's `__` follows enum-case rules no type lookup needs.
    private(set) var valueTypeSwiftNamesByCName: [String: Name] = [:]

    /// Renamed Swift name → original C name, all categories merged (renamed
    /// spellings do not collide the way C names do).
    private(set) var cNamesBySwiftName: [String: Name] = [:]

    /// C name → declaring module, for **every** listed entity, renamed or
    /// not. An APINotes file is the compiler's own record of which module a C
    /// declaration belongs to, so attribution registers unconditionally —
    /// including `SwiftPrivate` entities, whose C name is what manglings
    /// record.
    private(set) var moduleNamesByCName: [String: String] = [:]

    /// Objective-C class name → the naming annotations of the class and its
    /// members. Merged across files: several modules list `NSObject` to
    /// annotate their category methods, so members accumulate, a later file
    /// winning per member, and a listing without a class-level annotation
    /// keeps the earlier one.
    private(set) var classSwiftImportAnnotationsByName: [String: ObjCContainerSwiftImportAnnotations] = [:]

    /// Objective-C protocol name → the same, for protocols.
    private(set) var protocolSwiftImportAnnotationsByName: [String: ObjCContainerSwiftImportAnnotations] = [:]

    init(files: [APINotesFile]) {
        register(files: files)
    }

    /// Appends more files to the index. Within every table a later entry
    /// overwrites an earlier same-name one — the ordering hook the
    /// supplementary-file merge priority rides on (evolution proposal 0010:
    /// SDK APINotes first, then user-supplied files in caller order).
    mutating func register(files: [APINotesFile]) {
        for file in files {
            let module = file.apiNotesModule
            registerEntities(module.classes, declaredIn: file.moduleName, into: \.classSwiftNamesByCName)
            registerEntities(module.protocols, declaredIn: file.moduleName, into: \.protocolSwiftNamesByCName)
            registerEntities(module.tags, declaredIn: file.moduleName, into: \.valueTypeSwiftNamesByCName)
            registerEntities(module.enumerators, declaredIn: file.moduleName, into: \.valueTypeSwiftNamesByCName, prefixesSwiftPrivateNames: false)
            registerEntities(module.typedefs, declaredIn: file.moduleName, into: \.valueTypeSwiftNamesByCName)
            registerSwiftImportAnnotations(of: module.classes, into: \.classSwiftImportAnnotationsByName)
            registerSwiftImportAnnotations(of: module.protocols, into: \.protocolSwiftImportAnnotationsByName)
        }
    }

    /// The rename for `cName` in `category`. `.other` (a reference whose
    /// mangling does not pin the category, e.g. a typealias) consults the
    /// value-type then class tables, but never the protocol table — protocol
    /// references always mangle as protocols, and the `NSObject` name split
    /// is exactly what that isolation protects.
    ///
    /// `.objcClass` falls back to the value-type table on a class-table miss:
    /// a CF-bridged type reaches field metadata as a *foreign class* node
    /// spelled with its C tag name (`AGGraphStorage`, `CGContext` — the
    /// consuming binary emits a class-kind foreign descriptor for it), while
    /// its APINotes entry sits under `Tags`/`Typedefs` per C semantics. A tag
    /// and an ObjC class live in different C namespaces so they *can* share a
    /// name in principle, but the class table is consulted first, and a
    /// rename that exists only tag-side while a same-named distinct ObjC
    /// class is being referenced has no known real-world instance.
    func swiftName(forCName cName: String, category: ImportedTypeNameCategory) -> Name? {
        switch category {
        case .objcClass:
            return classSwiftNamesByCName[cName] ?? valueTypeSwiftNamesByCName[cName]
        case .objcProtocol:
            return protocolSwiftNamesByCName[cName]
        case .valueType:
            return valueTypeSwiftNamesByCName[cName]
        case .other:
            return valueTypeSwiftNamesByCName[cName] ?? classSwiftNamesByCName[cName]
        }
    }

    func cName(forSwiftName swiftName: String) -> Name? {
        cNamesBySwiftName[swiftName]
    }

    func moduleName(forCName cName: String) -> String? {
        moduleNamesByCName[cName]
    }

    func swiftImportAnnotations(forObjCClassNamed className: String) -> ObjCContainerSwiftImportAnnotations? {
        classSwiftImportAnnotationsByName[className]
    }

    func swiftImportAnnotations(forObjCProtocolNamed protocolName: String) -> ObjCContainerSwiftImportAnnotations? {
        protocolSwiftImportAnnotationsByName[protocolName]
    }

    private mutating func registerSwiftImportAnnotations(
        of containers: [some ObjCContext]?,
        into annotationTable: WritableKeyPath<Self, [String: ObjCContainerSwiftImportAnnotations]>
    ) {
        guard let containers else { return }
        for container in containers {
            var annotations = self[keyPath: annotationTable][container.name] ?? ObjCContainerSwiftImportAnnotations()
            if let declarationAnnotation = Self.swiftImportAnnotation(of: container) {
                annotations.declaration = declarationAnnotation
            }
            for method in container.methods ?? [] {
                guard let methodAnnotation = Self.swiftImportAnnotation(of: method) else { continue }
                annotations.members[.method(selector: method.selector, isClassMethod: method.kind == .class)] = methodAnnotation
            }
            for property in container.properties ?? [] {
                guard let propertyAnnotation = Self.swiftImportAnnotation(of: property) else { continue }
                // Without `PropertyKind` an entry names both the instance and
                // the class property, as Clang's API notes compiler reads it.
                let classPropertyFlags: [Bool] = switch property.kind {
                case .instance: [false]
                case .class: [true]
                case nil: [false, true]
                }
                for isClassProperty in classPropertyFlags {
                    annotations.members[.property(name: property.name, isClassProperty: isClassProperty)] = propertyAnnotation
                }
            }
            if !annotations.isEmpty {
                self[keyPath: annotationTable][container.name] = annotations
            }
        }
    }

    /// The naming annotation an API notes entry carries, or `nil` when it has
    /// neither a `SwiftName` nor `SwiftPrivate: true`.
    static func swiftImportAnnotation(of entity: some CommonEntity) -> SwiftImportAnnotation? {
        let swiftName = entity.swiftName.flatMap { $0.isEmpty ? nil : $0 }
        let isSwiftPrivate = entity.isSwiftPrivate == true
        guard swiftName != nil || isSwiftPrivate else { return nil }
        return SwiftImportAnnotation(swiftName: swiftName, isSwiftPrivate: isSwiftPrivate)
    }

    private mutating func registerEntities(
        _ entities: [some CommonEntity]?,
        declaredIn moduleName: String,
        into renameTable: WritableKeyPath<Self, [String: Name]>,
        prefixesSwiftPrivateNames: Bool = true
    ) {
        guard let entities else { return }
        for entity in entities {
            let cName = entity.name
            moduleNamesByCName[cName] = moduleName
            // A rename to the C name itself stays: ObjectiveC's entry renames
            // `NSObject` to `NSObject`, and that spelling is what keeps the
            // class in ObjectiveC against other modules' listings.
            guard let swiftName = Self.swiftName(of: entity, prefixesSwiftPrivateNames: prefixesSwiftPrivateNames) else { continue }
            self[keyPath: renameTable][cName] = Name(moduleName: moduleName, name: swiftName)
            cNamesBySwiftName[swiftName] = Name(moduleName: moduleName, name: cName)
        }
    }

    /// The name Swift imports `entity` under, when its API notes give it one:
    /// its `SwiftName`, else `__` and its C name when it is `SwiftPrivate`.
    static func swiftName(of entity: some CommonEntity, prefixesSwiftPrivateNames: Bool = true) -> String? {
        if let explicitSwiftName = entity.swiftName, !explicitSwiftName.isEmpty {
            return explicitSwiftName
        }
        if prefixesSwiftPrivateNames, entity.isSwiftPrivate == true {
            return "__" + entity.name
        }
        return nil
    }
}

#endif
