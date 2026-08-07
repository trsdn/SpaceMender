import Foundation

actor CleanupScanner {
    private let fileManager: FileManager
    private let calendar: Calendar

    init(fileManager: FileManager = .default, calendar: Calendar = .current) {
        self.fileManager = fileManager
        self.calendar = calendar
    }

    func scan(rule: CleanupRule, olderThanDays days: Int, now: Date = .now) throws -> CleanupScanResult {
        let items: [CleanupItem]

        switch rule.scanKind {
        case .files(let recursive, let extensions):
            let cutoff = try cutoffDate(days: days, now: now)
            items = try scanFiles(
                locations: rule.locations,
                recursive: recursive,
                extensions: extensions,
                cutoff: cutoff
            )
        case .childDirectories:
            let cutoff = try cutoffDate(days: days, now: now)
            items = try scanChildDirectories(locations: rule.locations, cutoff: cutoff)
        case .fixedLocations:
            items = try scanFixedLocations(rule.locations)
        case .unavailableSimulators:
            items = try scanUnavailableSimulators(rule: rule)
        case .homebrewCleanup:
            items = try scanHomebrewCleanup()
        }

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
        cutoff: Date
    ) throws -> [CleanupItem] {
        let keys = resourceKeys
        var items: [CleanupItem] = []

        for location in locations where fileManager.fileExists(atPath: location.path) {
            let urls: [URL]
            if recursive {
                guard let enumerator = fileManager.enumerator(
                    at: location,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else {
                    continue
                }
                urls = enumerator.compactMap { $0 as? URL }
            } else {
                urls = try fileManager.contentsOfDirectory(
                    at: location,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                )
            }

            for url in urls {
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
                items.append(makeItem(url: url, values: values, modifiedAt: modifiedAt))
            }
        }

        return items.sorted { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    private func scanChildDirectories(locations: [URL], cutoff: Date) throws -> [CleanupItem] {
        var items: [CleanupItem] = []

        for location in locations where fileManager.fileExists(atPath: location.path) {
            let children = try fileManager.contentsOfDirectory(
                at: location,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )

            for child in children {
                let values = try child.resourceValues(forKeys: resourceKeys)
                guard values.isDirectory == true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt < cutoff else {
                    continue
                }
                items.append(
                    CleanupItem(
                        id: child.path,
                        displayName: child.lastPathComponent,
                        url: child,
                        modifiedAt: modifiedAt,
                        allocatedSize: try allocatedSize(of: child)
                    )
                )
            }
        }

        return items.sorted { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    private func scanFixedLocations(_ locations: [URL]) throws -> [CleanupItem] {
        try locations.compactMap { location in
            guard fileManager.fileExists(atPath: location.path) else {
                return nil
            }
            let values = try location.resourceValues(forKeys: resourceKeys)
            return CleanupItem(
                id: location.path,
                displayName: location.lastPathComponent,
                url: location,
                modifiedAt: values.contentModificationDate,
                allocatedSize: try allocatedSize(of: location)
            )
        }
        .filter { $0.allocatedSize > 0 }
        .sorted { $0.allocatedSize > $1.allocatedSize }
    }

    private func scanUnavailableSimulators(rule: CleanupRule) throws -> [CleanupItem] {
        let output = try run(
            executable: URL(filePath: "/usr/bin/xcrun"),
            arguments: ["simctl", "list", "devices", "unavailable"]
        )
        let expression = try NSRegularExpression(
            pattern: #"\(([0-9A-Fa-f-]{36})\).*\(unavailable,"#
        )
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        let identifiers = expression.matches(in: output, range: range).compactMap { match -> String? in
            guard let swiftRange = Range(match.range(at: 1), in: output) else {
                return nil
            }
            return String(output[swiftRange]).uppercased()
        }

        guard let devicesRoot = rule.locations.first else {
            return []
        }

        return try identifiers.compactMap { identifier in
            let url = devicesRoot.appending(path: identifier, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: url.path) else {
                return nil
            }
            let values = try url.resourceValues(forKeys: resourceKeys)
            return CleanupItem(
                id: identifier,
                displayName: simulatorName(identifier: identifier, output: output),
                url: url,
                modifiedAt: values.contentModificationDate,
                allocatedSize: try allocatedSize(of: url)
            )
        }
        .sorted { $0.allocatedSize > $1.allocatedSize }
    }

    private func simulatorName(identifier: String, output: String) -> String {
        guard let line = output.split(separator: "\n").first(where: { $0.contains(identifier) }),
              let identifierRange = line.range(of: " (\(identifier))") else {
            return identifier
        }
        return line[..<identifierRange.lowerBound].trimmingCharacters(in: .whitespaces)
    }

    private func scanHomebrewCleanup() throws -> [CleanupItem] {
        let brew = URL(filePath: "/opt/homebrew/bin/brew")
        guard fileManager.isExecutableFile(atPath: brew.path) else {
            return []
        }

        let output = try run(executable: brew, arguments: ["cleanup", "--dry-run"])
        guard let bytes = parseApproximateBytes(output), bytes > 0 else {
            return []
        }

        return [
            CleanupItem(
                id: "homebrew-cleanup",
                displayName: "Homebrew packages and downloads",
                url: nil,
                modifiedAt: nil,
                allocatedSize: bytes
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
        modifiedAt: Date
    ) -> CleanupItem {
        CleanupItem(
            id: url.path,
            displayName: url.lastPathComponent,
            url: url,
            modifiedAt: modifiedAt,
            allocatedSize: Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0
            )
        )
    }

    private func run(executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw CleanupScannerError.commandFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }

    private var resourceKeys: Set<URLResourceKey> {
        [
            .isRegularFileKey,
            .isDirectoryKey,
            .contentModificationDateKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]
    }
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
