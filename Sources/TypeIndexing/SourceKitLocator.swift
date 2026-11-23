#if os(macOS)

import Foundation

/// Finds sourcekitd in a developer directory.
///
/// An Xcode keeps it in its default toolchain; the Command Line Tools have no
/// `Toolchains` level and keep it directly under `usr/lib`. Both ship it as
/// `sourcekitd.framework/Versions/A/sourcekitd`.
@available(macOS 13.0, *)
enum SourceKitLocator {
    /// Paths relative to a developer directory, in the order they are tried.
    static let relativeCandidatePaths = [
        "Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitd.framework/Versions/A/sourcekitd",
        "usr/lib/sourcekitd.framework/Versions/A/sourcekitd",
    ]

    /// The first candidate that exists under `developerDirectory`, or `nil`.
    static func sourceKitPath(
        inDeveloperDirectory developerDirectory: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        var directory = developerDirectory
        while directory.count > 1, directory.hasSuffix("/") {
            directory.removeLast()
        }
        return relativeCandidatePaths
            .map { directory + "/" + $0 }
            .first(where: fileExists)
    }

    /// sourcekitd in the active developer directory (`xcode-select -p`, or
    /// `DEVELOPER_DIR`), or `nil` when there is none or it has no sourcekitd.
    static func activeSourceKitPath() -> String? {
        guard let developerDirectory = try? Subprocess.activeDeveloperDirectory() else {
            return nil
        }
        return sourceKitPath(inDeveloperDirectory: developerDirectory)
    }
}

#endif
