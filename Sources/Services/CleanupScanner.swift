import Foundation

protocol CleanupScanning: Sendable {
    func scan(rule: CleanupRule, olderThanDays days: Int, now: Date) async throws -> CleanupScanResult
}

extension CleanupScanning {
    func scan(rule: CleanupRule, olderThanDays days: Int) async throws -> CleanupScanResult {
        try await scan(rule: rule, olderThanDays: days, now: .now)
    }
}

actor CleanupScanner: CleanupScanning {
    private let fileManager: FileManager
    private let calendar: Calendar
    private let commandRunner: any CommandRunning

    init(
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        commandRunner: any CommandRunning = CommandRunner()
    ) {
        self.fileManager = fileManager
        self.calendar = calendar
        self.commandRunner = commandRunner
    }

    func scan(
        rule: CleanupRule,
        olderThanDays days: Int,
        now: Date
    ) async throws -> CleanupScanResult {
        try Task.checkCancellation()
        let items: [CleanupItem]

        switch rule.scanKind {
        case .files(let recursive, let extensions):
            let cutoff = try cutoffDate(days: days, now: now)
            items = try scanFiles(
                locations: rule.locations,
                recursive: recursive,
                extensions: extensions,
                cutoff: cutoff,
                rule: rule,
                discoveredAt: now
            )
        case .childDirectories:
            let cutoff = try cutoffDate(days: days, now: now)
            items = try scanChildDirectories(
                locations: rule.locations,
                cutoff: cutoff,
                rule: rule,
                discoveredAt: now
            )
        case .fixedLocations:
            items = try scanFixedLocations(rule: rule, discoveredAt: now)
        case .unavailableSimulators:
            items = try await scanUnavailableSimulators(rule: rule, discoveredAt: now)
        case .homebrewCleanup:
            items = try await scanHomebrewCleanup(rule: rule, discoveredAt: now)
        }

        try Task.checkCancellation()
        return CleanupScanResult(rule: rule, items: items, scannedAt: now)
    }

    private func cutoffDate(days: Int, now: Date) throws -> Date {
        guard days >= 0 else {
            throw CleanupScannerError.invalidRetentionDays
        }
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else {
            throw CleanupScannerError.couldNotCalculateCutoff
        }
        return cutoff
    }

    private func scanFiles(
        locations: [URL],
        recursive: Bool,
        extensions: Set<String>?,
        cutoff: Date,
        rule: CleanupRule,
        discoveredAt: Date
    ) throws -> [CleanupItem] {
        let keys = resourceKeys
        var items: [CleanupItem] = []

        for location in locations where fileManager.fileExists(atPath: location.path) {
            try Task.checkCancellation()
            let urls: [URL]
            if recursive {
                guard let enumerator = fileManager.enumerator(
                    at: location,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else {
                    continue
                }
                var enumeratedURLs: [URL] = []
                for case let url as URL in enumerator {
                    try Task.checkCancellation()
                    enumeratedURLs.append(url)
                }
                urls = enumeratedURLs
            } else {
                urls = try fileManager.contentsOfDirectory(
                    at: location,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                )
            }

            for url in urls {
                try Task.checkCancellation()
                if let extensions,
                   !extensions.contains(url.pathExtension.lowercased()) {
                    continue
                }

                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt < cutoff else {
                    continue
                }
                items.append(
                    makeItem(
                        url: url,
                        values: values,
                        modifiedAt: modifiedAt,
                        rule: rule,
                        discoveredAt: discoveredAt
                    )
                )
            }
        }

        return items.sorted { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    private func scanChildDirectories(
        locations: [URL],
        cutoff: Date,
        rule: CleanupRule,
        discoveredAt: Date
    ) throws -> [CleanupItem] {
        var items: [CleanupItem] = []

        for location in locations where fileManager.fileExists(atPath: location.path) {
            try Task.checkCancellation()
            let children = try fileManager.contentsOfDirectory(
                at: location,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )

            for child in children {
                try Task.checkCancellation()
                let values = try child.resourceValues(forKeys: resourceKeys)
                guard values.isDirectory == true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt < cutoff else {
                    continue
                }
                items.append(
                    CleanupItem(
                        id: child.path,
                        providerID: rule.id,
                        stableIdentity: child.standardizedFileURL.path,
                        displayName: child.lastPathComponent,
                        url: child,
                        discoveredAt: discoveredAt,
                        modifiedAt: modifiedAt,
                        resourceIdentifier: resourceIdentifier(for: child),
                        allocatedSize: try allocatedSize(of: child),
                        cleanupPolicy: rule.cleanupPolicy
                    )
                )
            }
        }

        return items.sorted { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    private func scanFixedLocations(
        rule: CleanupRule,
        discoveredAt: Date
    ) throws -> [CleanupItem] {
        try rule.locations.compactMap { location in
            try Task.checkCancellation()
            guard fileManager.fileExists(atPath: location.path) else {
                return nil
            }
            let values = try location.resourceValues(forKeys: resourceKeys)
            return CleanupItem(
                id: location.path,
                providerID: rule.id,
                stableIdentity: location.standardizedFileURL.path,
                displayName: location.lastPathComponent,
                url: location,
                discoveredAt: discoveredAt,
                modifiedAt: values.contentModificationDate,
                resourceIdentifier: resourceIdentifier(for: location),
                allocatedSize: try allocatedSize(of: location),
                cleanupPolicy: rule.cleanupPolicy
            )
        }
        .filter { $0.allocatedSize > 0 }
        .sorted { $0.allocatedSize > $1.allocatedSize }
    }

    private func scanUnavailableSimulators(
        rule: CleanupRule,
        discoveredAt: Date
    ) async throws -> [CleanupItem] {
        let output = try await run(
            executable: URL(filePath: "/usr/bin/xcrun"),
            arguments: ["simctl", "list", "devices", "unavailable", "--json"]
        )
        let devices = try Self.decodeUnavailableSimulators(from: Data(output.utf8))

        guard let devicesRoot = rule.locations.first else {
            return []
        }

        return try devices.compactMap { device in
            try Task.checkCancellation()
            let identifier = device.udid.uppercased()
            let url = devicesRoot.appending(path: identifier, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: url.path) else {
                return nil
            }
            let values = try url.resourceValues(forKeys: resourceKeys)
            return CleanupItem(
                id: identifier,
                providerID: rule.id,
                stableIdentity: identifier,
                displayName: device.name,
                url: url,
                discoveredAt: discoveredAt,
                modifiedAt: values.contentModificationDate,
                resourceIdentifier: resourceIdentifier(for: url),
                allocatedSize: try allocatedSize(of: url),
                cleanupPolicy: rule.cleanupPolicy
            )
        }
        .sorted { $0.allocatedSize > $1.allocatedSize }
    }

    private func scanHomebrewCleanup(
        rule: CleanupRule,
        discoveredAt: Date
    ) async throws -> [CleanupItem] {
        let brew = URL(filePath: "/opt/homebrew/bin/brew")
        guard fileManager.isExecutableFile(atPath: brew.path) else {
            return []
        }

        let output = try await run(executable: brew, arguments: ["cleanup", "--dry-run"])
        guard let bytes = parseApproximateBytes(output), bytes > 0 else {
            return []
        }

        return [
            CleanupItem(
                id: "homebrew-cleanup",
                providerID: rule.id,
                stableIdentity: "homebrew-cleanup",
                displayName: "Homebrew packages and downloads",
                url: nil,
                discoveredAt: discoveredAt,
                modifiedAt: nil,
                resourceIdentifier: nil,
                allocatedSize: bytes,
                cleanupPolicy: rule.cleanupPolicy
            )
        ]
    }

    private func parseApproximateBytes(_ output: String) -> Int64? {
        guard let expression = try? NSRegularExpression(
            pattern: #"free approximately ([0-9]+(?:\.[0-9]+)?)([KMGT]?B)"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression.firstMatch(in: output, range: range),
              let numberRange = Range(match.range(at: 1), in: output),
              let unitRange = Range(match.range(at: 2), in: output),
              let number = Double(output[numberRange]) else {
            return nil
        }

        let multipliers: [String: Double] = [
            "B": 1,
            "KB": 1_000,
            "MB": 1_000_000,
            "GB": 1_000_000_000,
            "TB": 1_000_000_000_000
        ]
        guard let multiplier = multipliers[String(output[unitRange]).uppercased()] else {
            return nil
        }
        return Int64(number * multiplier)
    }

    private func allocatedSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: resourceKeys)
        if values.isRegularFile == true {
            return Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0
            )
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            try Task.checkCancellation()
            let childValues = try child.resourceValues(forKeys: resourceKeys)
            guard childValues.isRegularFile == true else {
                continue
            }
            total += Int64(
                childValues.totalFileAllocatedSize
                    ?? childValues.fileAllocatedSize
                    ?? childValues.fileSize
                    ?? 0
            )
        }
        return total
    }

    private func makeItem(
        url: URL,
        values: URLResourceValues,
        modifiedAt: Date,
        rule: CleanupRule,
        discoveredAt: Date
    ) -> CleanupItem {
        CleanupItem(
            id: url.path,
            providerID: rule.id,
            stableIdentity: url.standardizedFileURL.path,
            displayName: url.lastPathComponent,
            url: url,
            discoveredAt: discoveredAt,
            modifiedAt: modifiedAt,
            resourceIdentifier: resourceIdentifier(for: url),
            allocatedSize: Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0
            ),
            cleanupPolicy: rule.cleanupPolicy
        )
    }

    private func run(executable: URL, arguments: [String]) async throws -> String {
        let result = try await commandRunner.run(executable: executable, arguments: arguments)
        let output = String(decoding: result.standardOutput, as: UTF8.self)
        let error = String(decoding: result.standardError, as: UTF8.self)

        guard result.terminationStatus == 0 else {
            let message = error.isEmpty ? output : error
            throw CleanupScannerError.commandFailed(
                message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }

    private var resourceKeys: Set<URLResourceKey> {
        [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]
    }

    private func resourceIdentifier(for url: URL) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return "\(device.uint64Value):\(file.uint64Value)"
    }

    static func decodeUnavailableSimulators(from data: Data) throws -> [SimulatorDevice] {
        let listing = try JSONDecoder().decode(SimulatorListing.self, from: data)
        return listing.devices.values
            .flatMap { $0 }
            .filter { $0.isAvailable == false }
    }
}

struct SimulatorDevice: Decodable, Sendable {
    let name: String
    let udid: String
    let isAvailable: Bool
}

private struct SimulatorListing: Decodable {
    let devices: [String: [SimulatorDevice]]
}

enum CleanupScannerError: LocalizedError {
    case invalidRetentionDays
    case couldNotCalculateCutoff
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRetentionDays:
            "Retention days cannot be negative."
        case .couldNotCalculateCutoff:
            "SpaceMender could not calculate the cleanup cutoff date."
        case .commandFailed(let message):
            message.isEmpty ? "A cleanup tool could not inspect its data." : message
        }
    }
}
