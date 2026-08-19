import Foundation
import Testing
@testable import SpaceMender

/// Guards the size measurement against symlinks that sit *inside* a scanned tree.
///
/// `allocatedSize` used to call `enumerator.skipDescendants()` whenever it met a symlink. A
/// symlink is not a directory and is never followed, so there was nothing to skip — instead the
/// call skipped the remainder of the **enclosing** directory. macOS framework bundles put
/// `Versions/Current` and `Resources` symlinks right beside the payload, so everything after
/// them vanished from the total.
///
/// Measured on a real machine before the fix: the Playwright cache reported 206.5 MB of an
/// actual 564 MB — 262 of 365 files were never counted. Cleanup deletes the whole tree, so the
/// app promised the user less than a third of the space it would really free.
///
/// These tests build **real symlinks on disk**, because the bug lives in Foundation's
/// enumerator behaviour; a stubbed file manager would prove nothing.
struct AllocatedSizeSymlinkTests {
    @Test
    func siblingsFollowingASymlinkAreStillCounted() throws {
        let fixture = try FrameworkLikeFixture()
        defer { fixture.cleanUp() }
        #expect(try fixture.preconditionHolds(), "Fixture must enumerate the symlink first")

        let measured = try FilesystemProviderSupport.allocatedSize(
            of: fixture.root,
            fileManager: .default
        )

        #expect(
            measured >= Int64(fixture.expectedPayloadBytes),
            """
            Every regular file under the root must be counted. Anything less means the \
            enumerator stopped early at the symlink and dropped its siblings — the app would \
            under-report how much space cleanup frees.
            """
        )
    }

    @Test
    func fileCountIsUnaffectedByAPrecedingSymlink() throws {
        let withLink = try FrameworkLikeFixture(includeSymlink: true)
        defer { withLink.cleanUp() }
        let withoutLink = try FrameworkLikeFixture(includeSymlink: false)
        defer { withoutLink.cleanUp() }

        let linked = try FilesystemProviderSupport.allocatedSize(
            of: withLink.root,
            fileManager: .default
        )
        let plain = try FilesystemProviderSupport.allocatedSize(
            of: withoutLink.root,
            fileManager: .default
        )

        #expect(
            linked == plain,
            """
            Two trees with identical regular files must measure identically. The only \
            difference here is a symlink, which contributes no bytes of its own.
            """
        )
    }

    /// The fix must not turn into issue #2's mistake: the symlink is skipped, never resolved.
    @Test
    func symlinkTargetOutsideTheTreeIsNotCounted() throws {
        let fixture = try FrameworkLikeFixture()
        defer { fixture.cleanUp() }

        let measured = try FilesystemProviderSupport.allocatedSize(
            of: fixture.root,
            fileManager: .default
        )

        #expect(
            measured < Int64(fixture.outsideTargetBytes),
            """
            The symlink points at a deliberately huge directory outside the scanned tree. \
            Counting it would mean the size claims space that deleting this root never frees.
            """
        )
    }
}

/// Mimics the layout that exposed the bug. Two properties are essential, and a fixture missing
/// either one passes even against the broken code — this was found the hard way:
///
/// 1. The symlink must live in a **subdirectory** of the scanned root. `skipDescendants()` after
///    an entry at the top level of the enumeration does nothing.
/// 2. The symlink must be enumerated **before** the payload directory, since it skips what
///    follows. The real names are reused because directory order is by name (alphabetical on
///    HFS+, by name hash on APFS) and is therefore stable — `preconditionHolds` asserts it
///    rather than trusting it.
private struct FrameworkLikeFixture {
    let base: URL
    let root: URL
    let bundle: URL
    let outside: URL
    let expectedPayloadBytes: Int
    let outsideTargetBytes: Int

    init(includeSymlink: Bool = true) throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "allocated-size-\(UUID().uuidString)", directoryHint: .isDirectory)
        root = base.appending(path: "cache-root", directoryHint: .isDirectory)
        bundle = root.appending(path: "Chromium.framework", directoryHint: .isDirectory)
        outside = base.appending(path: "outside", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        // Large enough that counting it would be unmistakable in the assertion.
        let outsidePayload = Data(repeating: 0xAB, count: 256 * 1024)
        try outsidePayload.write(to: outside.appending(path: "must-not-be-counted.bin"))
        outsideTargetBytes = outsidePayload.count

        if includeSymlink {
            try FileManager.default.createSymbolicLink(
                at: bundle.appending(path: "Resources"),
                withDestinationURL: outside
            )
        }

        let versions = bundle.appending(path: "Versions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        let payload = Data(repeating: 0xCD, count: 64 * 1024)
        try payload.write(to: versions.appending(path: "payload.bin"))
        expectedPayloadBytes = payload.count
    }

    /// True when the symlink really is enumerated before the payload, so the test is testing
    /// something. Without this the suite could go green on a filesystem that orders entries the
    /// other way round, and quietly stop guarding the bug.
    func preconditionHolds() throws -> Bool {
        let entries = try FileManager.default.contentsOfDirectory(
            at: bundle,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        )
        guard
            let linkIndex = entries.firstIndex(where: {
                (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            }),
            let payloadIndex = entries.firstIndex(where: { $0.lastPathComponent == "Versions" })
        else {
            return false
        }
        return linkIndex < payloadIndex
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: base)
    }
}
