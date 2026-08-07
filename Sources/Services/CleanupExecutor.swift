import AppKit
import Foundation

@MainActor
protocol RunningApplicationChecking {
    func runningApplicationNames(
        bundleIdentifiers: Set<String>,
        names: Set<String>
    ) -> [String]
}

@MainActor
struct RunningApplicationChecker: RunningApplicationChecking {
    func runningApplicationNames(
        bundleIdentifiers: Set<String>,
        names: Set<String>
    ) -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            let bundleMatches = application.bundleIdentifier.map(bundleIdentifiers.contains) ?? false
            let nameMatches = application.localizedName.map { applicationName in
                names.contains { configuredName in
                    applicationName == configuredName
                        || applicationName.hasPrefix(configuredName + " ")
                }
            } ?? false
            return bundleMatches || nameMatches ? application.localizedName : nil
        }
    }
}

protocol FileTrashing {
    func trashItem(at url: URL) throws
}

struct WorkspaceFileTrasher: FileTrashing {
    func trashItem(at url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

@MainActor
protocol CleanupExecuting {
    func clean(rule: CleanupRule, items: [CleanupItem]) -> CleanupReport
}

@MainActor
struct CleanupExecutor: CleanupExecuting {
    private let fileManager: FileManager
    private let commandRunner: any CommandRunning
    private let runningApplicationChecker: any RunningApplicationChecking
    private let fileTrasher: any FileTrashing

    init(
        fileManager: FileManager = .default,
        commandRunner: any CommandRunning = CommandRunner(),
        runningApplicationChecker: any RunningApplicationChecking = RunningApplicationChecker(),
        fileTrasher: any FileTrashing = WorkspaceFileTrasher()
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.runningApplicationChecker = runningApplicationChecker
        self.fileTrasher = fileTrasher
    }

    func clean(rule: CleanupRule, items: [CleanupItem]) -> CleanupReport {
        guard !items.isEmpty else {
            return CleanupReport(outcomes: [])
        }

        if let reason = rule.cleanupUnavailableReason {
            return CleanupReport(outcomes: items.map { failed($0, message: reason) })
        }

        let runningApplications = runningApplicationChecker.runningApplicationNames(
            bundleIdentifiers: rule.affectedApplicationBundleIdentifiers,
            names: rule.affectedApplicationNames
        )
        if !runningApplications.isEmpty {
            let names = runningApplications.sorted().joined(separator: ", ")
            return CleanupReport(
                outcomes: items.map {
                    failed($0, message: "Quit \(names), rescan, and try again.")
                }
            )
        }

        switch rule.cleanupAction {
        case .deleteItems:
            return CleanupReport(outcomes: items.map { cleanFileItem($0, rule: rule) })
        case .deleteUnavailableSimulators:
            return cleanSimulators(rule: rule, items: items)
        case .runHomebrewCleanup:
            return cleanHomebrew(items: items)
        case .unavailable(let reason):
            return CleanupReport(outcomes: items.map { failed($0, message: reason) })
        }
    }

    private func cleanFileItem(_ item: CleanupItem, rule: CleanupRule) -> CleanupItemOutcome {
        do {
            let url = try validatedURL(for: item, rule: rule)
            switch item.cleanupPolicy {
            case .permanentDelete:
                try fileManager.removeItem(at: url)
                return cleaned(item)
            case .permanentDeleteContents:
                try deleteValidatedContents(
                    of: url,
                    rule: rule,
                    discoveredAt: item.discoveredAt
                )
                return cleaned(item)
            case .moveToTrash:
                try fileTrasher.trashItem(at: url)
                return outcome(item, status: .movedToTrash)
            case .unavailable, .deleteSimulator, .externalCommand:
                return failed(item, message: "The item’s cleanup policy does not match this rule.")
            }
        } catch let error as CleanupValidationError {
            return outcome(item, status: .skippedChanged, message: error.localizedDescription)
        } catch {
            return failed(item, message: error.localizedDescription)
        }
    }

    private func cleanSimulators(rule: CleanupRule, items: [CleanupItem]) -> CleanupReport {
        let currentUnavailable: Set<String>
        do {
            let result = try successfulCommand(
                executable: URL(filePath: "/usr/bin/xcrun"),
                arguments: ["simctl", "list", "devices", "unavailable", "--json"]
            )
            currentUnavailable = Set(
                try CleanupScanner.decodeUnavailableSimulators(from: result.standardOutput)
                    .map { $0.udid.uppercased() }
            )
        } catch {
            return CleanupReport(outcomes: items.map { failed($0, message: error.localizedDescription) })
        }

        var outcomes: [CleanupItemOutcome] = []
        var validItems: [CleanupItem] = []

        for item in items {
            guard item.providerID == rule.id,
                  item.cleanupPolicy == .deleteSimulator,
                  item.id == item.stableIdentity,
                  currentUnavailable.contains(item.id.uppercased()) else {
                outcomes.append(
                    outcome(
                        item,
                        status: .skippedChanged,
                        message: "The simulator is no longer an unavailable device."
                    )
                )
                continue
            }
            do {
                _ = try validatedURL(for: item, rule: rule)
                validItems.append(item)
            } catch let error as CleanupValidationError {
                outcomes.append(
                    outcome(item, status: .skippedChanged, message: error.localizedDescription)
                )
            } catch {
                outcomes.append(failed(item, message: error.localizedDescription))
            }
        }

        guard !validItems.isEmpty else {
            return CleanupReport(outcomes: outcomes)
        }

        do {
            _ = try successfulCommand(
                executable: URL(filePath: "/usr/bin/xcrun"),
                arguments: ["simctl", "delete"] + validItems.map(\.id)
            )
            outcomes.append(contentsOf: validItems.map(cleaned))
        } catch {
            outcomes.append(contentsOf: validItems.map { failed($0, message: error.localizedDescription) })
        }
        return CleanupReport(outcomes: outcomes)
    }

    private func cleanHomebrew(items: [CleanupItem]) -> CleanupReport {
        do {
            _ = try successfulCommand(
                executable: URL(filePath: "/opt/homebrew/bin/brew"),
                arguments: ["cleanup"]
            )
            return CleanupReport(outcomes: items.map(cleaned))
        } catch {
            return CleanupReport(outcomes: items.map { failed($0, message: error.localizedDescription) })
        }
    }

    private func validatedURL(for item: CleanupItem, rule: CleanupRule) throws -> URL {
        guard item.providerID == rule.id,
              item.cleanupPolicy == rule.cleanupPolicy,
              let url = item.url else {
            throw CleanupValidationError.providerMismatch
        }
        if item.cleanupPolicy == .deleteSimulator {
            guard item.stableIdentity == item.id else {
                throw CleanupValidationError.providerMismatch
            }
        } else {
            guard item.stableIdentity == url.standardizedFileURL.path else {
                throw CleanupValidationError.providerMismatch
            }
        }

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey
            ])
        } catch {
            throw CleanupValidationError.missing
        }

        guard values.isSymbolicLink != true, rule.contains(url) else {
            throw CleanupValidationError.unsafePath
        }
        guard item.resourceIdentifier == resourceIdentifier(for: url),
              datesMatch(item.modifiedAt, values.contentModificationDate) else {
            throw CleanupValidationError.changed
        }

        switch rule.scanKind {
        case .files(_, let extensions):
            guard values.isRegularFile == true else {
                throw CleanupValidationError.providerMismatch
            }
            if let extensions, !extensions.contains(url.pathExtension.lowercased()) {
                throw CleanupValidationError.providerMismatch
            }
        case .childDirectories, .fixedLocations, .unavailableSimulators:
            guard values.isDirectory == true else {
                throw CleanupValidationError.providerMismatch
            }
        case .homebrewCleanup:
            throw CleanupValidationError.providerMismatch
        }

        if item.cleanupPolicy == .permanentDeleteContents {
            let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard rule.locations.contains(where: {
                $0.standardizedFileURL.resolvingSymlinksInPath().path == candidate
            }) else {
                throw CleanupValidationError.unsafePath
            }
        }
        return url
    }

    private func deleteValidatedContents(
        of root: URL,
        rule: CleanupRule,
        discoveredAt: Date
    ) throws {
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .isSymbolicLinkKey,
                .contentModificationDateKey
            ],
            options: []
        )

        for child in children {
            try validateTree(
                at: child,
                under: rule,
                discoveredAt: discoveredAt
            )
        }
        for child in children {
            try fileManager.removeItem(at: child)
        }
    }

    private func validateTree(
        at url: URL,
        under rule: CleanupRule,
        discoveredAt: Date
    ) throws {
        let keys: Set<URLResourceKey> = [
            .isSymbolicLinkKey,
            .isDirectoryKey,
            .contentModificationDateKey
        ]
        let values = try url.resourceValues(forKeys: keys)
        guard rule.contains(url), values.isSymbolicLink != true else {
            throw CleanupValidationError.unsafePath
        }
        if let modifiedAt = values.contentModificationDate,
           modifiedAt > discoveredAt.addingTimeInterval(0.001) {
            throw CleanupValidationError.changed
        }
        guard values.isDirectory == true,
              let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: []
              ) else {
            return
        }
        for case let child as URL in enumerator {
            let childValues = try child.resourceValues(forKeys: keys)
            guard rule.contains(child), childValues.isSymbolicLink != true else {
                throw CleanupValidationError.unsafePath
            }
            if let modifiedAt = childValues.contentModificationDate,
               modifiedAt > discoveredAt.addingTimeInterval(0.001) {
                throw CleanupValidationError.changed
            }
        }
    }

    private func successfulCommand(
        executable: URL,
        arguments: [String]
    ) throws -> CommandResult {
        let result = try commandRunner.run(executable: executable, arguments: arguments)
        guard result.terminationStatus == 0 else {
            let error = String(decoding: result.standardError, as: UTF8.self)
            let output = String(decoding: result.standardOutput, as: UTF8.self)
            let message = (error.isEmpty ? output : error)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CleanupExecutorError.commandFailed(
                message.isEmpty ? "The cleanup tool failed." : message
            )
        }
        return result
    }

    private func resourceIdentifier(for url: URL) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return "\(device.uint64Value):\(file.uint64Value)"
    }

    private func datesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            abs(lhs.timeIntervalSince(rhs)) < 0.001
        default:
            false
        }
    }

    private func cleaned(_ item: CleanupItem) -> CleanupItemOutcome {
        outcome(item, status: .cleaned)
    }

    private func failed(_ item: CleanupItem, message: String) -> CleanupItemOutcome {
        outcome(item, status: .failed, message: message)
    }

    private func outcome(
        _ item: CleanupItem,
        status: CleanupOutcomeStatus,
        message: String? = nil
    ) -> CleanupItemOutcome {
        CleanupItemOutcome(
            itemID: item.id,
            displayName: item.displayName,
            status: status,
            message: message
        )
    }
}

enum CleanupValidationError: LocalizedError {
    case missing
    case unsafePath
    case changed
    case providerMismatch

    var errorDescription: String? {
        switch self {
        case .missing:
            "The item no longer exists."
        case .unsafePath:
            "The item is a symlink or is no longer inside its allowed cleanup root."
        case .changed:
            "The item changed after it was scanned."
        case .providerMismatch:
            "The item no longer matches this cleanup category."
        }
    }
}

enum CleanupExecutorError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            message
        }
    }
}
