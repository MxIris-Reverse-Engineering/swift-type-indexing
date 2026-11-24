# AGENTS.md

Guidance for coding agents working in this repository.

## What this is

`swift-type-indexing` (module `TypeIndexing`) resolves the C and Objective-C types Swift manglings
spell as `__C.X`: which module declares `X`, what Swift calls it, and which API notes annotations
(`SwiftName`, `SwiftPrivate`) an Objective-C class, protocol or member carries. It reads the SDKs of
the active developer directory; it reads no Mach-O file. How the pipeline works and why each part has
its shape: `Documentations/Internal/TypeIndexingPipeline.md` — read it before changing a source file.

It came out of MachOSwiftSection, which holds the proposal that moved it
([0105-swift-type-indexing-package](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0105-swift-type-indexing-package.md) in MachOSwiftSection's `Documentations/Evolutions/`).

## Rules

- **Depend on nothing from MachOSwiftSection or MachOObjCSection.** MachOObjCSection depends on this
  package, and MachOSwiftSection on both; a dependency back would be a cycle. Runtime metadata comes in
  through `DeclaredTypeNameSource`, which MachOObjCSection implements.
- **Every source file is wrapped in `#if os(macOS)`**, and every type carries
  `@available(macOS 13.0, *)`. The package declares the same platforms as the MachO packages so they
  can depend on it; they do so with `.when(platforms: [.macOS])`.
- **Logging uses FrameworkToolbox's protocol-form `@Loggable`** (a `fileprivate protocol XxxLogging`
  plus an `@available` conformance), subsystem `com.mxiris.type-indexing`. The direct form fails to
  compile on an `@available` type — see the pipeline document.
- **Public API is what MachOObjCSection, MachOSwiftSection and RuntimeViewer use**; everything else
  is internal, and tests reach it through `@testable import TypeIndexing`.
- **API notes outrank module interfaces, which outrank runtime metadata** — decided at query time,
  never by registration order, because `index(dependencies:moduleFilter:)` may be called again later.
- **A renamed Swift name follows the Clang importer**: `SwiftName` wins as is; `SwiftPrivate` alone
  prefixes `__` to the C name.
- **Tests never touch the real cache directory** (`Application Support/swift-type-indexing`): pass a
  temporary `cacheDirectory`, or drive the `register` steps directly.

## Building and testing

```bash
swift build --build-tests
swift test
```

`USING_LOCAL_DEPENDENCIES=1` makes `Package.swift` take the swift-apinotes fork from
`../../../Fork/Library/swift-apinotes` when that checkout exists, for testing a change to it before it
is released.

## Documentation

- Index: `Documentations/README.md`.
- Proposals live in MachOSwiftSection's `Documentations/Evolutions/` until this package needs its own;
  `Documentations/Evolutions/README.md` links them.
