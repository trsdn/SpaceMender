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

    @Test
    func unauthorizedClientFailsClosed() {
        let policy = DefenderClientAuthorizationPolicy(
            requirement: #"identifier "app.spacemender.SpaceMender""#,
            signatureChecker: FixedSignatureChecker(result: false)
        )

        #expect(!policy.authorizes(auditToken: Data(repeating: 7, count: 32)))
        #expect(
            !DefenderClientAuthorizationPolicy(
                requirement: nil,
                signatureChecker: FixedSignatureChecker(result: true)
            ).authorizes(auditToken: Data(repeating: 7, count: 32))
        )
    }
}

private struct FixedSignatureChecker: DefenderCodeSignatureChecking {
    let result: Bool

    func isValid(auditToken: Data, requirement: String) -> Bool {
        result
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
