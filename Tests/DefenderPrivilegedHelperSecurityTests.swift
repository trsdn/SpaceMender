import Darwin
import Foundation
import Testing
@testable import SpaceMender

// A real SMAppService install and audit-token signing handshake requires signed
// app/helper products. These tests intentionally exercise the same identity,
// authorization-policy, and unlink validation code only under temporary roots.
struct DefenderPrivilegedHelperSecurityTests {
    @Test
    func validSelectedArchiveIsRemovedOnlyFromIsolatedRoot() throws {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        let file = try fixture.makeArchive(name: "wdavdiag-old.zip")
        let identity = try fixture.identity(for: file)

        try fixture.validator.remove(identity)

        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func arbitraryPathsCannotBeRepresentedAsCandidateIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        let identity = DefenderCandidateIdentity(
            fileName: "../outside.zip",
            resourceIdentifier: "1:2",
            modifiedAt: .distantPast,
            discoveredAt: .now,
            cutoffDate: .now
        )

        #expect(throws: DefenderArchiveValidationError.invalidIdentity) {
            try fixture.validator.validate(identity)
        }
    }

    @Test
    func symlinkArchiveIsRejectedWithoutTouchingDestination() throws {
        let fixture = try Fixture()
        let outside = try Fixture()
        defer {
            fixture.removeRoot()
            outside.removeRoot()
        }
        let destination = try outside.makeArchive(name: "keep.zip")
        let link = fixture.root.appending(path: "linked.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        let destinationIdentity = try outside.identity(for: destination)
        let identity = DefenderCandidateIdentity(
            fileName: link.lastPathComponent,
            resourceIdentifier: destinationIdentity.resourceIdentifier,
            modifiedAt: destinationIdentity.modifiedAt,
            discoveredAt: destinationIdentity.discoveredAt,
            cutoffDate: destinationIdentity.cutoffDate
        )

        #expect(throws: DefenderArchiveValidationError.symbolicLink) {
            try fixture.validator.remove(identity)
        }
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func changedResourceIdentityIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        let file = try fixture.makeArchive(name: "changed.zip")
        let original = try fixture.identity(for: file)
        try FileManager.default.removeItem(at: file)
        _ = try fixture.makeArchive(name: "changed.zip")

        #expect(throws: DefenderArchiveValidationError.changed) {
            try fixture.validator.remove(original)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func changedModificationTimeIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        let file = try fixture.makeArchive(name: "retouched.zip")
        let identity = try fixture.identity(for: file)
        try FileManager.default.setAttributes(
            [.modificationDate: identity.modifiedAt.addingTimeInterval(10)],
            ofItemAtPath: file.path
        )

        #expect(throws: DefenderArchiveValidationError.changed) {
            try fixture.validator.remove(identity)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func candidateNewerThanScanCutoffIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        let file = try fixture.makeArchive(name: "recent.zip")
        let identity = try fixture.identity(
            for: file,
            cutoffDate: Date(timeIntervalSince1970: 1)
        )

        #expect(throws: DefenderArchiveValidationError.tooRecent) {
            try fixture.validator.remove(identity)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func symlinkedConfiguredRootIsRejectedAsInvalidRoot() throws {
        let actual = try Fixture()
        let links = try Fixture()
        defer {
            actual.removeRoot()
            links.removeRoot()
        }
        let file = try actual.makeArchive(name: "linked-root.zip")
        let linkedRoot = links.root.appending(path: "wdavdiag", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: actual.root)
        let validator = DefenderArchiveValidator(
            configuration: DefenderArchiveValidationConfiguration(
                root: linkedRoot,
                requiredOwnerUID: getuid()
            )
        )
        let identity = try actual.identity(for: file)

        #expect(throws: DefenderArchiveValidationError.invalidRoot) {
            try validator.validate(identity)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func directoryDisguisedAsZipIsRejectedAsNonRegular() throws {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        let directory = fixture.root.appending(path: "folder.zip", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: directory.path
        )
        let identity = try fixture.identity(for: directory)

        #expect(throws: DefenderArchiveValidationError.notRegularZip) {
            try fixture.validator.validate(identity)
        }
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    /// Replaces `unauthorizedClientFailsClosed`, which exercised
    /// `DefenderClientAuthorizationPolicy` — a type no production code ever called. It passed
    /// while the helper's real defence went unchecked, which is worse than no test at all.
    ///
    /// The real invariant lives in two artefacts the test target cannot link against
    /// (`HelperSources` is a separate target), so they are asserted from source. See
    /// `Tests/ReleaseScriptSafetyTests.swift` for the same technique.
    @Test
    func helperRefusesToRunWithoutAClientRequirement() throws {
        let main = try helperSource("DefenderHelperMain.swift")

        #expect(
            main.contains("setConnectionCodeSigningRequirement(requirement)"),
            """
            Authorization is enforced by handing the requirement to the listener; Foundation \
            then checks each peer's audit token before the delegate is consulted.
            """
        )
        #expect(
            main.contains("!requirement.isEmpty else {") && main.contains("exit(EXIT_FAILURE)"),
            """
            A missing or empty requirement must be fatal. Continuing without one would let the \
            helper accept every caller with root privileges.
            """
        )
    }

    @Test
    func declaredClientRequirementIsNarrowEnoughToBeWorthEnforcing() throws {
        let plist = try #require(
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: repositoryFile("Configuration/DefenderHelper-Info.plist")),
                format: nil
            ) as? [String: Any]
        )
        let requirement = try #require(
            plist["SpaceMenderAuthorizedClientRequirement"] as? String,
            "Without this key the helper exits at launch and Defender cleanup silently never works"
        )

        #expect(
            requirement.contains("anchor apple generic"),
            "Omitting the anchor would accept ad-hoc and self-signed impostors"
        )
        #expect(
            requirement.contains(#"identifier "app.spacemender.SpaceMender""#),
            "The requirement must name this app, not merely any Apple-anchored binary"
        )
        #expect(
            requirement.contains("certificate leaf[subject.OU]"),
            "Pinning the team OU stops another developer's App Store build from qualifying"
        )
    }

    /// The delegate must not regrow a hand-rolled authorization check: it cannot see
    /// unauthorized peers, so any such check would be unreachable and misleading.
    @Test
    func listenerDelegateDoesNotClaimValidationItNeverPerforms() throws {
        let delegate = try helperSource("DefenderHelperListenerDelegate.swift")

        #expect(
            !delegate.contains("Accepted client after audit-token code-signing validation"),
            "The delegate performs no validation; the log line claimed otherwise"
        )
        #expect(
            !delegate.contains("DefenderClientAuthorizationPolicy"),
            "Authorization belongs on the listener, where Foundation actually enforces it"
        )
    }

    private func repositoryFile(_ relativePath: String) -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
    }

    private func helperSource(_ name: String) throws -> String {
        try String(contentsOf: repositoryFile("HelperSources/\(name)"), encoding: .utf8)
    }
}

private struct Fixture {
    let root: URL
    let validator: DefenderArchiveValidator

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        validator = DefenderArchiveValidator(
            configuration: DefenderArchiveValidationConfiguration(
                root: root,
                requiredOwnerUID: getuid()
            )
        )
    }

    func makeArchive(name: String) throws -> URL {
        let file = root.appending(path: name)
        try Data("fixture".utf8).write(to: file)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        return file
    }

    func identity(
        for file: URL,
        cutoffDate: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) throws -> DefenderCandidateIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let device = try #require(attributes[.systemNumber] as? NSNumber)
        let inode = try #require(attributes[.systemFileNumber] as? NSNumber)
        let modifiedAt = try #require(attributes[.modificationDate] as? Date)
        return DefenderCandidateIdentity(
            fileName: file.lastPathComponent,
            resourceIdentifier: "\(device.uint64Value):\(inode.uint64Value)",
            modifiedAt: modifiedAt,
            discoveredAt: Date(timeIntervalSince1970: 1_900_000_000),
            cutoffDate: cutoffDate
        )
    }

    func removeRoot() {
        try? FileManager.default.removeItem(at: root)
    }
}
