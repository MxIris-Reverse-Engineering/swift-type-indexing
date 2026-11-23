# swift-type-indexing

Resolve the C and Objective-C types a Swift mangling spells as `__C.X` to the module that declares
them and to the name Swift gives them, using the SDKs installed on the Mac.

A mangled name records an imported type by its C (Objective-C runtime) name under the placeholder
module `__C`. Neither the declaring module nor the Swift name survives into the binary: a type renamed
with `NS_SWIFT_NAME`, or hidden with `NS_REFINED_FOR_SWIFT`, mangles exactly like one that was not.
`TypeIndexing` reads the answers back from the SDK:

| Mangled | Resolved | Why |
|---|---|---|
| `__C.UITraitCollection` | `UIKit.UITraitCollection` | declared by UIKit |
| `__C.UICellConfigurationState` | `UIKit.__UICellConfigurationState` | `SwiftPrivate: true` in `UIKit.apinotes` |
| `__C.PKDrawing` | `PencilKit.PKDrawingReference` | `SwiftName: PKDrawingReference` in `PencilKit.apinotes` |
| `__C.CFStringRef` | `CoreFoundation.CFString` | the CF bridge strips `Ref` |

It also tells an Objective-C header printer which classes, protocols and members carry
`NS_SWIFT_NAME(...)` or `NS_REFINED_FOR_SWIFT`.

## Sources

`TypeDatabase` merges three sources, in priority order:

1. **API notes** — every `.apinotes` file in the SDK, plus any supplementary files you pass.
2. **Module interfaces** — the Swift view of each SDK module your binary depends on, generated with
   sourcekitd and cached per SDK build.
3. **Runtime metadata** — the types each dependency image declares, through `DeclaredTypeNameSource`.
   This package reads no Mach-O file itself; [MachOObjCSection](https://github.com/MxIris-Reverse-Engineering/MachOObjCSection)'s
   `ObjCTypeIndexing` provides a source over Objective-C metadata.

## Usage

```swift
import TypeIndexing

// UIKit on the Mac is Mac Catalyst: the macOS SDK read through System/iOSSupport.
let typeDatabase = TypeDatabase(platform: .macCatalyst)
try await typeDatabase.index(dependencies: [], moduleFilter: { ["UIKit", "Foundation"].contains($0) })

await typeDatabase.moduleName(forTypeName: "UICellConfigurationState")                   // "UIKit"
await typeDatabase.swiftName(forCName: "UICellConfigurationState", category: .objcClass) // "__UICellConfigurationState"
await typeDatabase.swiftImportAnnotations(forObjCClassNamed: "UICellConfigurationState")?.declaration
// SwiftImportAnnotation(swiftName: nil, isSwiftPrivate: true)
```

`TypeIndexingAvailability.availability(for:)` says whether the Mac can index a platform before you
try. To print resolved names in Swift interfaces, use
[MachOSwiftSection](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection)'s
`SwiftTypeNameResolution`, or `swift-section interface --resolve-c-module-names`.

## Requirements

- macOS 13 or later at run time. Every source file is `#if os(macOS)`; on other platforms the module
  is empty, so packages that also build for iOS depend on it with a macOS-only condition.
- A developer directory with the platform's SDK: Xcode, or the Command Line Tools for macOS and
  Mac Catalyst. Without sourcekitd only the module-interface source is skipped.
- The first interface of a large module takes a while — UIKit's about two minutes — and is then
  cached per SDK build, in `Application Support/swift-type-indexing` unless you pass a
  `cacheDirectory`.

## Installation

```swift
.package(url: "https://github.com/MxIris-Reverse-Engineering/swift-type-indexing", from: "0.1.0"),
```

```swift
.product(name: "TypeIndexing", package: "swift-type-indexing", condition: .when(platforms: [.macOS])),
```

## License

MIT. See [LICENSE](LICENSE).
