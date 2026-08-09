import Darwin
import Foundation
import os

struct DefenderArchiveValidationConfiguration: Sendable {
    let root: URL
    let requiredOwnerUID: uid_t?

    static let production = DefenderArchiveValidationConfiguration(
        root: DefenderHelperConstants.productionRoot,
        requiredOwnerUID: 0
    )
}

enum DefenderArchiveValidationError: Error, Equatable {
    case invalidIdentity
    case invalidRoot
    case missing
    case symbolicLink
    case notRegularZip
    case wrongOwner
    case outsideRoot
    case changed
    case tooRecent
    case couldNotDelete
}

struct DefenderArchiveValidator: Sendable {
    private let configuration: DefenderArchiveValidationConfiguration

    init(configuration: DefenderArchiveValidationConfiguration = .production) {
        self.configuration = configuration
    }

    func validate(_ identity: DefenderCandidateIdentity) throws {
        let descriptor = try validatedDescriptor(for: identity)
        close(descriptor)
    }

    func remove(_ identity: DefenderCandidateIdentity) throws {
        let rootDescriptor = open(configuration.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootDescriptor >= 0 else {
            throw DefenderArchiveValidationError.invalidRoot
        }
        defer { close(rootDescriptor) }

        let descriptor = try validatedDescriptor(for: identity, rootDescriptor: rootDescriptor)
        close(descriptor)

        guard unlinkat(rootDescriptor, identity.fileName, 0) == 0 else {
            throw DefenderArchiveValidationError.couldNotDelete
        }
    }

    private func validatedDescriptor(
        for identity: DefenderCandidateIdentity,
        rootDescriptor suppliedRootDescriptor: Int32? = nil
    ) throws -> Int32 {
        try validateIdentityShape(identity)

        let rootDescriptor = suppliedRootDescriptor
            ?? open(configuration.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootDescriptor >= 0 else {
            throw DefenderArchiveValidationError.invalidRoot
        }
        defer {
            if suppliedRootDescriptor == nil {
                close(rootDescriptor)
            }
        }

        let descriptor = openat(rootDescriptor, identity.fileName, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw DefenderArchiveValidationError.symbolicLink
            }
            throw DefenderArchiveValidationError.missing
        }

        do {
            try validateDescriptor(descriptor, identity: identity)
            try validateCanonicalLocation(identity.fileName)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func validateIdentityShape(_ identity: DefenderCandidateIdentity) throws {
        guard !identity.fileName.isEmpty,
              identity.fileName == URL(filePath: identity.fileName).lastPathComponent,
              !identity.fileName.contains("/"),
              identity.fileName.lowercased().hasSuffix(".zip"),
              !identity.resourceIdentifier.isEmpty
        else {
            throw DefenderArchiveValidationError.invalidIdentity
        }
    }

    private func validateDescriptor(
        _ descriptor: Int32,
        identity: DefenderCandidateIdentity
    ) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw DefenderArchiveValidationError.missing
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw DefenderArchiveValidationError.notRegularZip
        }
        if let requiredOwnerUID = configuration.requiredOwnerUID,
           metadata.st_uid != requiredOwnerUID {
            throw DefenderArchiveValidationError.wrongOwner
        }

        let currentResourceIdentifier = "\(UInt64(metadata.st_dev)):\(UInt64(metadata.st_ino))"
        guard currentResourceIdentifier == identity.resourceIdentifier else {
            throw DefenderArchiveValidationError.changed
        }

        let currentModifiedAt = Date(
            timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
                + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        guard abs(currentModifiedAt.timeIntervalSince(identity.modifiedAt)) < 0.001 else {
            throw DefenderArchiveValidationError.changed
        }
        guard currentModifiedAt <= identity.discoveredAt else {
            throw DefenderArchiveValidationError.changed
        }
        guard currentModifiedAt <= identity.cutoffDate else {
            throw DefenderArchiveValidationError.tooRecent
        }
    }

    private func validateCanonicalLocation(_ fileName: String) throws {
        let canonicalRoot = configuration.root.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalRoot.path == configuration.root.standardizedFileURL.path else {
            throw DefenderArchiveValidationError.invalidRoot
        }

        let candidate = configuration.root
            .appending(path: fileName, directoryHint: .notDirectory)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard candidate.deletingLastPathComponent().path == canonicalRoot.path else {
            throw DefenderArchiveValidationError.outsideRoot
        }
    }
}

extension DefenderArchiveValidationError {
    var outcomeMessage: String {
        switch self {
        case .changed, .tooRecent, .missing:
            "The archive changed after the scan."
        case .symbolicLink, .notRegularZip, .wrongOwner, .outsideRoot, .invalidIdentity, .invalidRoot:
            "The archive failed the helper safety checks."
        case .couldNotDelete:
            "The helper could not remove the validated archive."
        }
    }
}
