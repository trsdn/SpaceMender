import Foundation
import Testing
@testable import SpaceMender

/// Guards the invariant behind issue #6: the size SpaceMender *reports* for an item must match
/// the space that deleting that item actually frees.
///
/// Deletion (`removeItem`) and validation (`validateTree`) both traverse bundles in full, so
/// measurement must too. When `allocatedSize` skipped package descendants, a cache directory
/// containing a `.app`, `.framework` or `.xcarchive` was reported far smaller than it was —
/// exactly the shape of a real Xcode DerivedData folder.
struct PackageSizeAccountingTests {
    @Test
    func sizeOfDirectoryIncludesContentsOfNestedBundles() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let plainPayload = Data(repeating: 0xAB, count: 4_096)
        let bundlePayload = Data(repeating: 0xCD, count: 16_384)

        try plainPayload.write(to: root.appending(path: "plain.bin"))
        let bundleBinary = root
            .appending(path: "Nested.app", directoryHint: .isDirectory)
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundleBinary, withIntermediateDirectories: true)
        try bundlePayload.write(to: bundleBinary.appending(path: "Nested"))

        let measured = try FilesystemProviderSupport.allocatedSize(of: root, fileManager: .default)
        let actuallyOnDisk = try sizeByFullTraversal(of: root)

        #expect(
            measured == actuallyOnDisk,
            """
            Reported size must equal what deleting the directory frees. \
            Reported \(measured) bytes, on disk \(actuallyOnDisk) bytes — \
            a gap means the bundle payload was not counted.
            """
        )
        #expect(
            measured >= Int64(plainPayload.count + bundlePayload.count),
            "Reported \(measured) bytes must cover both the plain file and the bundle payload"
        )
    }

    @Test
    func sizeOfBundleItselfCountsItsPayload() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = root.appending(path: "Standalone.app", directoryHint: .isDirectory)
        let binaryDirectory = bundle
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0xEF, count: 8_192).write(to: binaryDirectory.appending(path: "Standalone"))

        let measured = try FilesystemProviderSupport.allocatedSize(of: bundle, fileManager: .default)

        #expect(
            measured == (try sizeByFullTraversal(of: bundle)),
            "A bundle passed as the item itself must report its full payload, got \(measured) bytes"
        )
    }

    /// Independent oracle: a plain recursive walk with no enumeration options at all, matching
    /// how `validateTree` and `removeItem` see the tree.
    private func sizeByFullTraversal(of url: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            let values = try child.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
