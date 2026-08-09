import Foundation

struct CleanupExecutionPlan: Sendable {
    let providerID: String
    let items: [CleanupItem]
    let createdAt: Date
}

enum CleanupProviderAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

struct CleanupRunningApplicationBehavior: Sendable {
    let bundleIdentifiers: Set<String>
    let processNames: Set<String>
}

protocol CleanupProvider: Sendable {
    var rule: CleanupRule { get }
    var previewMetadata: CleanupRule { get }
    var safetyMetadata: CleanupSafetyMetadata { get }
    var availability: CleanupProviderAvailability { get }
    var runningApplicationBehavior: CleanupRunningApplicationBehavior { get }

    func discover(olderThanDays days: Int, now: Date) async throws -> [CleanupItem]
    func validate(_ item: CleanupItem) async throws
    func makeExecutionPlan(items: [CleanupItem]) async -> CleanupExecutionPlan
    func execute(plan: CleanupExecutionPlan) async -> CleanupReport
}

extension CleanupProvider {
    var previewMetadata: CleanupRule {
        rule
    }

    var safetyMetadata: CleanupSafetyMetadata {
        rule.safety
    }

    var availability: CleanupProviderAvailability {
        if let reason = rule.cleanupUnavailableReason {
            return .unavailable(reason: reason)
        }
        return .available
    }

    var runningApplicationBehavior: CleanupRunningApplicationBehavior {
        CleanupRunningApplicationBehavior(
            bundleIdentifiers: rule.affectedApplicationBundleIdentifiers,
            processNames: rule.affectedApplicationNames
        )
    }

    func scan(olderThanDays days: Int, now: Date) async throws -> CleanupScanResult {
        try Task.checkCancellation()
        let items = try await discover(olderThanDays: days, now: now)
        try Task.checkCancellation()
        return CleanupScanResult(rule: rule, items: items, scannedAt: now)
    }

    func makeExecutionPlan(items: [CleanupItem]) async -> CleanupExecutionPlan {
        CleanupExecutionPlan(providerID: rule.id, items: items, createdAt: .now)
    }
}

struct CleanupProviderCatalog: Sendable {
    private let providersByID: [String: any CleanupProvider]

    init(providers: [any CleanupProvider]) {
        providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.rule.id, $0) })
    }

    var providers: [any CleanupProvider] {
        providersByID.values.sorted { $0.rule.id < $1.rule.id }
    }

    var rules: [CleanupRule] {
        var rankedRules: [(rank: Int, rule: CleanupRule)] = []
        for provider in providers {
            let providerRule = provider.previewMetadata
            let rank = Self.builtInOrder.firstIndex(of: providerRule.id) ?? Int.max
            rankedRules.append((rank, providerRule))
        }
        rankedRules.sort {
            $0.rank == $1.rank ? $0.rule.id < $1.rule.id : $0.rank < $1.rank
        }
        return rankedRules.map(\.rule)
    }

    func provider(id: String) -> (any CleanupProvider)? {
        providersByID[id]
    }

    static var builtIn: CleanupProviderCatalog {
        builtIn()
    }

    static func builtIn(
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        commandRunner: any CommandRunning = CommandRunner(),
        runningApplicationChecker: any RunningApplicationChecking = RunningApplicationChecker(),
        fileTrasher: any FileTrashing = WorkspaceFileTrasher(),
        defenderHelper: any DefenderPrivilegedHelperServing = DefenderPrivilegedHelperClient(),
        npmCacheRootDiscoverer: any NpmCacheRootDiscovering = NpmEnvironmentCacheRootDiscoverer(
            commandRunner: CommandRunner()
        ),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CleanupProviderCatalog {
        let files = FilesystemProviderSupport(
            fileManager: fileManager,
            calendar: calendar,
            runningApplicationChecker: runningApplicationChecker,
            fileTrasher: fileTrasher
        )
        return CleanupProviderCatalog(providers: [
            PrivilegedOperationProvider(
                rule: .defenderDiagnostics,
                files: files,
                recursive: false,
                extensions: ["zip"],
                helper: defenderHelper
            ),
            SimulatorCleanupProvider(
                rule: .unavailableSimulators,
                fileManager: fileManager,
                commandRunner: commandRunner,
                runningApplicationChecker: runningApplicationChecker
            ),
            ChildDirectoryCleanupProvider(rule: .xcodeDerivedData, files: files),
            NpmCacheCleanupProvider(
                rule: .npmCaches,
                files: files,
                discoverer: npmCacheRootDiscoverer
            ),
            FixedCacheRootsCleanupProvider(rule: .swiftPMCache, files: files),
            FixedCacheRootsCleanupProvider(rule: .playwrightCache, files: files),
            FixedCacheRootsCleanupProvider(rule: .copilotCache, files: files),
            BrowserProfileCacheCleanupProvider(rule: .browserCaches, files: files),
            AgeFilteredFilesCleanupProvider(
                rule: .userLogs,
                files: files,
                recursive: true,
                extensions: nil
            ),
            ExternalCommandCleanupProvider.homebrew(
                rule: .homebrewCleanup,
                fileManager: fileManager,
                commandRunner: commandRunner,
                runningApplicationChecker: runningApplicationChecker,
                environment: environment
            )
        ])
    }

    private static let builtInOrder = [
        "microsoft-defender-diagnostics",
        "xcode-unavailable-simulators",
        "xcode-derived-data",
        "npm-caches",
        "swiftpm-cache",
        "playwright-cache",
        "copilot-cache",
        "browser-caches",
        "user-logs",
        "homebrew-cleanup"
    ]
}

final class AgeFilteredFilesCleanupProvider: CleanupProvider, @unchecked Sendable {
    let rule: CleanupRule
    private let files: FilesystemProviderSupport
    private let recursive: Bool
    private let extensions: Set<String>?

    init(
        rule: CleanupRule,
        files: FilesystemProviderSupport,
        recursive: Bool,
        extensions: Set<String>?
    ) {
        self.rule = rule
        self.files = files
        self.recursive = recursive
        self.extensions = extensions
    }

    func discover(olderThanDays days: Int, now: Date) async throws -> [CleanupItem] {
        try files.scanFiles(
            rule: rule,
            recursive: recursive,
            extensions: extensions,
            olderThanDays: days,
            now: now
        )
    }

    func validate(_ item: CleanupItem) async throws {
        _ = try files.validatedURL(
            for: item,
            rule: rule,
            expected: .regularFile(extensions: extensions)
        )
    }

    func execute(plan: CleanupExecutionPlan) async -> CleanupReport {
        await files.executeFilesystemPlan(
            plan,
            rule: rule,
            expected: .regularFile(extensions: extensions)
        )
    }
}

final class ChildDirectoryCleanupProvider: CleanupProvider, @unchecked Sendable {
    let rule: CleanupRule
    private let files: FilesystemProviderSupport

    init(rule: CleanupRule, files: FilesystemProviderSupport) {
        self.rule = rule
        self.files = files
    }

    func discover(olderThanDays days: Int, now: Date) async throws -> [CleanupItem] {
        try files.scanChildDirectories(rule: rule, olderThanDays: days, now: now)
    }

    func validate(_ item: CleanupItem) async throws {
        _ = try files.validatedURL(for: item, rule: rule, expected: .childDirectoryActivity)
    }

    func execute(plan: CleanupExecutionPlan) async -> CleanupReport {
        await files.executeFilesystemPlan(plan, rule: rule, expected: .childDirectoryActivity)
    }
}

final class FixedCacheRootsCleanupProvider: CleanupProvider, @unchecked Sendable {
    let rule: CleanupRule
    private let files: FilesystemProviderSupport

    init(rule: CleanupRule, files: FilesystemProviderSupport) {
        self.rule = rule
        self.files = files
    }

    func discover(olderThanDays days: Int, now: Date) async throws -> [CleanupItem] {
        try files.scanFixedRoots(rule: rule, now: now)
    }

    func validate(_ item: CleanupItem) async throws {
        _ = try files.validatedURL(for: item, rule: rule, expected: .exactRoot)
    }

    func execute(plan: CleanupExecutionPlan) async -> CleanupReport {
        await files.executeFilesystemPlan(plan, rule: rule, expected: .exactRoot)
    }
}

final class PrivilegedOperationProvider: CleanupProvider, @unchecked Sendable {
    private let baseRule: CleanupRule
    private let discovery: AgeFilteredFilesCleanupProvider
    private let helper: any DefenderPrivilegedHelperServing

    var rule: CleanupRule {
        baseRule.withCleanupUnavailableReason(helper.cachedAvailability.unavailableReason)
    }

    init(
        rule: CleanupRule,
        files: FilesystemProviderSupport,
        recursive: Bool,
        extensions: Set<String>?,
        helper: any DefenderPrivilegedHelperServing
    ) {
        baseRule = rule
        self.helper = helper
        discovery = AgeFilteredFilesCleanupProvider(
            rule: rule.withCleanupUnavailableReason(nil),
            files: files,
            recursive: recursive,
            extensions: extensions
        )
    }

    func discover(olderThanDays days: Int, now: Date) async throws -> [CleanupItem] {
        _ = await helper.refreshAvailability()
        return try await discovery.discover(olderThanDays: days, now: now)
    }

    func validate(_ item: CleanupItem) async throws {
        try await discovery.validate(item)
    }

    func execute(plan: CleanupExecutionPlan) async -> CleanupReport {
        guard await helper.refreshAvailability() == .ready else {
            let reason = helper.cachedAvailability.unavailableReason
                ?? "The privileged helper is not ready."
            return CleanupReport(
                outcomes: plan.items.map {
                    CleanupItemOutcome(
                        itemID: $0.id,
                        displayName: $0.displayName,
                        status: .failed,
                        message: reason
                    )
                }
            )
        }

        var identities: [DefenderCandidateIdentity] = []
        var outcomesByName: [String: CleanupItemOutcome] = [:]
        for item in plan.items {
            do {
                try await validate(item)
                guard let url = item.url,
                      let modifiedAt = item.modifiedAt,
                      let cutoffDate = item.eligibilityCutoff,
                      let resourceIdentifier = item.resourceIdentifier
                else {
                    throw CleanupValidationError.changed
                }
                identities.append(
                    DefenderCandidateIdentity(
                        fileName: url.lastPathComponent,
                        resourceIdentifier: resourceIdentifier,
                        modifiedAt: modifiedAt,
                        discoveredAt: item.discoveredAt,
                        cutoffDate: cutoffDate
                    )
                )
            } catch {
                outcomesByName[item.displayName] = CleanupItemOutcome(
                    itemID: item.id,
                    displayName: item.displayName,
                    status: .skippedChanged,
                    message: "The archive changed after the scan."
                )
            }
        }

        do {
            let helperOutcomes = try await helper.remove(candidates: identities)
            for helperOutcome in helperOutcomes {
                guard let item = plan.items.first(where: { $0.displayName == helperOutcome.fileName }) else {
                    continue
                }
                let status: CleanupOutcomeStatus
                switch helperOutcome.status {
                case .cleaned:
                    status = .cleaned
                case .skippedChanged, .rejected:
                    status = .skippedChanged
                case .failed:
                    status = .failed
                }
                outcomesByName[helperOutcome.fileName] = CleanupItemOutcome(
                    itemID: item.id,
                    displayName: item.displayName,
                    status: status,
                    message: helperOutcome.message
                )
            }
        } catch {
            for item in plan.items where outcomesByName[item.displayName] == nil {
                outcomesByName[item.displayName] = CleanupItemOutcome(
                    itemID: item.id,
                    displayName: item.displayName,
                    status: .failed,
                    message: "The privileged helper connection failed."
                )
            }
        }

        return CleanupReport(
            outcomes: plan.items.compactMap { outcomesByName[$0.displayName] }
        )
    }
}

final class SimulatorCleanupProvider: CleanupProvider, @unchecked Sendable {
    let rule: CleanupRule
    private let fileManager: FileManager
    private let commandRunner: any CommandRunning
    private let runningApplicationChecker: any RunningApplicationChecking

    init(
        rule: CleanupRule,
        fileManager: FileManager,
        commandRunner: any CommandRunning,
        runningApplicationChecker: any RunningApplicationChecking
    ) {
        self.rule = rule
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.runningApplicationChecker = runningApplicationChecker
    }

    func discover(olderThanDays days: Int, now: Date) async throws -> [CleanupItem] {
        let result = try await commandRunner.run(
            executable: URL(filePath: "/usr/bin/xcrun"),
            arguments: ["simctl", "list", "devices", "unavailable", "--json"]
        )
        let devices = try SimulatorListing.decodeUnavailable(from: result)
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
            let values = try url.resourceValues(forKeys: FilesystemProviderSupport.resourceKeys)
            return CleanupItem(
                id: identifier,
                providerID: rule.id,
                stableIdentity: identifier,
                displayName: device.name,
                url: url,
                discoveredAt: now,
                modifiedAt: values.contentModificationDate,
                resourceIdentifier: FilesystemProviderSupport.resourceIdentifier(
                    for: url,
                    fileManager: fileManager
                ),
                allocatedSize: try FilesystemProviderSupport.allocatedSize(
                    of: url,
                    fileManager: fileManager
                ),
                cleanupPolicy: rule.cleanupPolicy
            )
        }
        .sorted { $0.allocatedSize > $1.allocatedSize }
    }

    func validate(_ item: CleanupItem) async throws {
        guard item.providerID == rule.id,
              item.cleanupPolicy == .deleteSimulator,
              item.id == item.stableIdentity,
              let url = item.url else {
            throw CleanupValidationError.providerMismatch
        }
        try FilesystemProviderSupport.validateResource(
            item: item,
            url: url,
            rule: rule,
            expected: .directory,
            fileManager: fileManager
        )
    }

    func execute(plan: CleanupExecutionPlan) async -> CleanupReport {
        if let blocked = await blockedOutcomes(plan.items) {
            return CleanupReport(outcomes: blocked)
        }

        let currentUnavailable: Set<String>
        do {
            // Fetch the full device listing (not just the unavailable ones)
            // so cleanup can also detect that CoreSimulator is actively
            // booting, running, or creating an unrelated device before it
            // performs a bulk `simctl delete`.
            let result = try await commandRunner.run(
                executable: URL(filePath: "/usr/bin/xcrun"),
                arguments: ["simctl", "list", "devices", "--json"]
            )
            let allDevices = try SimulatorListing.decodeAll(from: result)
            let activeDevices = allDevices.filter(\.isActive)
            guard activeDevices.isEmpty else {
                let names = activeDevices.map(\.name).sorted().joined(separator: ", ")
                return CleanupReport(
                    outcomes: plan.items.map {
                        failed(
                            $0,
                            message: "CoreSimulator is currently active (\(names)). Quit or "
                                + "shut down active simulators, rescan, and try again."
                        )
                    }
                )
            }
            currentUnavailable = Set(
                allDevices.filter { !$0.isAvailable }.map { $0.udid.uppercased() }
            )
        } catch {
            return CleanupReport(outcomes: plan.items.map { commandOutcome($0, error: error, categoryName: rule.name) })
        }

        var outcomes: [CleanupItemOutcome] = []
        var validItems: [CleanupItem] = []
        for item in plan.items {
            if Task.isCancelled {
                outcomes.append(cancelled(item))
                continue
            }
            guard currentUnavailable.contains(item.id.uppercased()) else {
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
                try await validate(item)
                validItems.append(item)
            } catch let error as CleanupValidationError {
                outcomes.append(
                    outcome(item, status: .skippedChanged, message: error.localizedDescription)
                )
            } catch {
                let presentation = UserFacingError.cleanup(error, categoryName: rule.name)
                outcomes.append(failed(
                    item,
                    message: presentation.alertMessage,
                    technicalDetails: presentation.technicalDetails
                ))
            }
        }

        guard !validItems.isEmpty else {
            return CleanupReport(outcomes: outcomes)
        }
        do {
            let result = try await commandRunner.run(
                executable: URL(filePath: "/usr/bin/xcrun"),
                arguments: ["simctl", "delete"] + validItems.map(\.id)
            )
            try requireSuccessfulCommand(result)
            outcomes.append(contentsOf: validItems.map(cleaned))
        } catch {
            outcomes.append(contentsOf: validItems.map { commandOutcome($0, error: error, categoryName: rule.name) })
        }
        return CleanupReport(outcomes: outcomes)
    }

    private func blockedOutcomes(_ items: [CleanupItem]) async -> [CleanupItemOutcome]? {
        let applications = await runningApplicationChecker.runningApplicationNames(
            bundleIdentifiers: rule.affectedApplicationBundleIdentifiers,
            names: rule.affectedApplicationNames
        )
        guard !applications.isEmpty else {
            return nil
        }
        let names = applications.sorted().joined(separator: ", ")
        return items.map { failed($0, message: "Quit \(names), rescan, and try again.") }
    }
}

final class ExternalCommandCleanupProvider: CleanupProvider, @unchecked Sendable {
    let rule: CleanupRule
    private let fileManager: FileManager
    private let commandRunner: any CommandRunning
    private let runningApplicationChecker: any RunningApplicationChecking
    private let executableCandidates: [URL]
    private let previewArguments: [String]
    private let executionArguments: [String]
    private let previewParser: @Sendable (String) -> ExternalCommandPreviewEstimate
    private let warningsSummarizer: (@Sendable (String) -> String?)?

    init(
        rule: CleanupRule,
        fileManager: FileManager,
        commandRunner: any CommandRunning,
        runningApplicationChecker: any RunningApplicationChecking,
        executableCandidates: [URL],
        previewArguments: [String],
        executionArguments: [String],
        previewParser: @escaping @Sendable (String) -> ExternalCommandPreviewEstimate,
        warningsSummarizer: (@Sendable (String) -> String?)? = nil
    ) {
        self.rule = rule
        self.fileManager = fileManager
        self.commandRunner = commandRunner
        self.runningApplicationChecker = runningApplicationChecker
        self.executableCandidates = executableCandidates
        self.previewArguments = previewArguments
        self.executionArguments = executionArguments
        self.previewParser = previewParser
        self.warningsSummarizer = warningsSummarizer
    }

    /// Discovers Homebrew at its Apple Silicon default prefix, its Intel
    /// default prefix, and any explicitly configured `HOMEBREW_PREFIX`
    /// location, in that preference order. GUI apps do not inherit a login
    /// shell's `PATH`, so SpaceMender checks these well-known locations
    /// directly rather than relying on `PATH` lookup.
    static func homebrew(
        rule: CleanupRule,
        fileManager: FileManager,
        commandRunner: any CommandRunning,
        runningApplicationChecker: any RunningApplicationChecking,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ExternalCommandCleanupProvider {
        var candidates: [URL] = []
        if let configuredPrefix = environment["HOMEBREW_PREFIX"], !configuredPrefix.isEmpty {
            candidates.append(
                URL(filePath: configuredPrefix, directoryHint: .isDirectory)
                    .appending(path: "bin/brew")
            )
        }
        candidates.append(URL(filePath: "/opt/homebrew/bin/brew")) // Apple Silicon default
        candidates.append(URL(filePath: "/usr/local/bin/brew")) // Intel default
        return ExternalCommandCleanupProvider(
            rule: rule,
            fileManager: fileManager,
            commandRunner: commandRunner,
            runningApplicationChecker: runningApplicationChecker,
            executableCandidates: candidates,
            previewArguments: ["cleanup", "--dry-run"],
            executionArguments: ["cleanup"],
            previewParser: parseHomebrewEstimate,
            warningsSummarizer: summarizeHomebrewWarnings
        )
    }

    private func resolveExecutable() -> URL? {
        executableCandidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    func discover(olderThanDays days: Int, now: Date) async throws -> [CleanupItem] {
        guard let executable = resolveExecutable() else {
            return []
        }
        let result = try await commandRunner.run(
            executable: executable,
            arguments: previewArguments
        )
        try requireSuccessfulCommand(result)
        let standardOutput = String(decoding: result.standardOutput, as: UTF8.self)
        let standardError = String(decoding: result.standardError, as: UTF8.self)
        let notice = warningsSummarizer?(standardOutput + "\n" + standardError)

        switch previewParser(standardOutput) {
        case .nothingToClean:
            return []
        case .unknown:
            return [
                CleanupItem(
                    id: rule.id,
                    providerID: rule.id,
                    stableIdentity: rule.id,
                    displayName: "\(rule.name) items",
                    url: nil,
                    discoveredAt: now,
                    modifiedAt: nil,
                    resourceIdentifier: nil,
                    allocatedSize: 0,
                    cleanupPolicy: rule.cleanupPolicy,
                    notice: notice ?? "The reclaimable size could not be determined reliably.",
                    hasUnknownSize: true
                )
            ]
        case .known(let bytes):
            guard bytes > 0 else {
                return []
            }
            return [
                CleanupItem(
                    id: rule.id,
                    providerID: rule.id,
                    stableIdentity: rule.id,
                    displayName: "\(rule.name) items",
                    url: nil,
                    discoveredAt: now,
                    modifiedAt: nil,
                    resourceIdentifier: nil,
                    allocatedSize: bytes,
                    cleanupPolicy: rule.cleanupPolicy,
                    notice: notice
                )
            ]
        }
    }

    func validate(_ item: CleanupItem) async throws {
        guard item.providerID == rule.id,
              item.cleanupPolicy == rule.cleanupPolicy,
              item.id == item.stableIdentity,
              item.url == nil,
              resolveExecutable() != nil else {
            throw CleanupValidationError.providerMismatch
        }
    }

    func execute(plan: CleanupExecutionPlan) async -> CleanupReport {
        let applications = await runningApplicationChecker.runningApplicationNames(
            bundleIdentifiers: rule.affectedApplicationBundleIdentifiers,
            names: rule.affectedApplicationNames
        )
        if !applications.isEmpty {
            let names = applications.sorted().joined(separator: ", ")
            return CleanupReport(
                outcomes: plan.items.map {
                    failed($0, message: "Quit \(names), rescan, and try again.")
                }
            )
        }
        guard resolveExecutable() != nil else {
            return CleanupReport(
                outcomes: plan.items.map {
                    failed($0, message: "The cleanup tool is no longer available on this Mac.")
                }
            )
        }
        do {
            for item in plan.items {
                try await validate(item)
            }
            guard let executable = resolveExecutable() else {
                throw CleanupProviderError.commandFailed("")
            }
            let result = try await commandRunner.run(
                executable: executable,
                arguments: executionArguments
            )
            try requireSuccessfulCommand(result)
            return CleanupReport(outcomes: plan.items.map(cleaned))
        } catch {
            return CleanupReport(outcomes: plan.items.map { commandOutcome($0, error: error, categoryName: rule.name) })
        }
    }

    /// Homebrew always emits `Would remove: ...` lines (and, on older
    /// releases, `Would free up ...`) followed by a final
    /// `This operation would free approximately X of disk space.` summary
    /// when there is something to clean; it emits neither when there is
    /// nothing to do. Warning-heavy output (for example dozens of
    /// `Warning: Skipping <formula>: ...` lines for outdated local
    /// formulae) never changes that signal.
    private static func parseHomebrewEstimate(_ output: String) -> ExternalCommandPreviewEstimate {
        let hasRemovalIndication = output.contains("Would remove:")
            || output.range(of: #"(?i)would\s+free"#, options: .regularExpression) != nil
        guard hasRemovalIndication else {
            return .nothingToClean
        }
        guard let bytes = parseApproximateBytes(output), bytes > 0 else {
            return .unknown
        }
        return .known(bytes: bytes)
    }

    /// Captures `Warning:`-prefixed lines instead of surfacing Homebrew's
    /// raw, potentially very long dry-run output.
    private static func summarizeHomebrewWarnings(_ output: String) -> String? {
        let warningLines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("Warning:") }
        guard !warningLines.isEmpty else {
            return nil
        }
        let shown = warningLines.prefix(2).joined(separator: " ")
        let remaining = warningLines.count - 2
        guard remaining > 0 else {
            return shown
        }
        return "\(shown) (+\(remaining) more warning\(remaining == 1 ? "" : "s"))"
    }

    private static func parseApproximateBytes(_ output: String) -> Int64? {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?:free approximately|would free(?:\s+up)?)\s+([0-9]+(?:[.,][0-9]+)?)\s*([KMGT]?B)"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression.firstMatch(in: output, range: range),
              let numberRange = Range(match.range(at: 1), in: output),
              let unitRange = Range(match.range(at: 2), in: output),
              let number = Double(output[numberRange].replacingOccurrences(of: ",", with: ".")) else {
            return nil
        }
        let multipliers: [String: Double] = [
            "B": 1, "KB": 1_000, "MB": 1_000_000,
            "GB": 1_000_000_000, "TB": 1_000_000_000_000
        ]
        guard let multiplier = multipliers[String(output[unitRange]).uppercased()] else {
            return nil
        }
        return Int64(number * multiplier)
    }
}

enum ExternalCommandPreviewEstimate: Sendable, Equatable {
    case nothingToClean
    case unknown
    case known(bytes: Int64)
}

final class FilesystemProviderSupport: @unchecked Sendable {
    enum ExpectedResource {
        case regularFile(extensions: Set<String>?)
        case directory
        case childDirectoryActivity
        case exactRoot
        /// An immediate child directory of one of the rule's declared
        /// roots (for example one browser profile's cache folder), where
        /// neither the item nor any of its descendants may use a name in
        /// `excludedNames`.
        case cacheRootChild(excludedNames: Set<String>)
    }

    private let fileManager: FileManager
    private let calendar: Calendar
    private let runningApplicationChecker: any RunningApplicationChecking
    private let fileTrasher: any FileTrashing

    init(
        fileManager: FileManager,
        calendar: Calendar,
        runningApplicationChecker: any RunningApplicationChecking,
        fileTrasher: any FileTrashing
    ) {
        self.fileManager = fileManager
        self.calendar = calendar
        self.runningApplicationChecker = runningApplicationChecker
        self.fileTrasher = fileTrasher
    }

    func scanFiles(
        rule: CleanupRule,
        recursive: Bool,
        extensions: Set<String>?,
        olderThanDays days: Int,
        now: Date
    ) throws -> [CleanupItem] {
        let cutoff = try cutoffDate(days: days, now: now)
        var items: [CleanupItem] = []
        for location in rule.locations where fileManager.fileExists(atPath: location.path) {
            try Task.checkCancellation()
            let urls: [URL]
            if recursive {
                // A per-item error handler keeps one unreadable subdirectory
                // (permission-denied, disconnected volume, and so on) from
                // silently aborting discovery of the rest of the tree; the
                // erroring branch is skipped and enumeration continues.
                guard let enumerator = fileManager.enumerator(
                    at: location,
                    includingPropertiesForKeys: Array(Self.resourceKeys),
                    options: [.skipsPackageDescendants],
                    errorHandler: { _, _ in true }
                ) else {
                    continue
                }
                var found: [URL] = []
                for case let url as URL in enumerator {
                    try Task.checkCancellation()
                    found.append(url)
                }
                urls = found
            } else {
                urls = try fileManager.contentsOfDirectory(
                    at: location,
                    includingPropertiesForKeys: Array(Self.resourceKeys),
                    options: []
                )
            }

            for url in urls {
                try Task.checkCancellation()
                if let extensions, !extensions.contains(url.pathExtension.lowercased()) {
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: Self.resourceKeys) else {
                    // An item that became unreadable between enumeration and
                    // inspection is skipped rather than failing the scan.
                    continue
                }
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt < cutoff else {
                    continue
                }
                items.append(
                    makeItem(
                        url: url,
                        values: values,
                        modifiedAt: modifiedAt,
                        eligibilityCutoff: cutoff,
                        rule: rule,
                        now: now
                    )
                )
            }
        }
        return items.sorted { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    func scanChildDirectories(
        rule: CleanupRule,
        olderThanDays days: Int,
        now: Date
    ) throws -> [CleanupItem] {
        let cutoff = try cutoffDate(days: days, now: now)
        var items: [CleanupItem] = []
        for location in rule.locations where fileManager.fileExists(atPath: location.path) {
            let children = try fileManager.contentsOfDirectory(
                at: location,
                includingPropertiesForKeys: Array(Self.resourceKeys),
                options: [.skipsHiddenFiles]
            )
            for child in children {
                try Task.checkCancellation()
                let values = try child.resourceValues(forKeys: Self.resourceKeys)
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    continue
                }
                let activityDate = try Self.boundedActivityDate(
                    for: child,
                    fallback: values.contentModificationDate,
                    fileManager: fileManager
                )
                guard let activityDate, activityDate < cutoff else {
                    continue
                }
                items.append(
                    CleanupItem(
                        id: child.path,
                        providerID: rule.id,
                        stableIdentity: child.standardizedFileURL.path,
                        displayName: child.lastPathComponent,
                        url: child,
                        discoveredAt: now,
                        modifiedAt: activityDate,
                        resourceIdentifier: Self.resourceIdentifier(for: child, fileManager: fileManager),
                        allocatedSize: try Self.allocatedSize(of: child, fileManager: fileManager),
                        cleanupPolicy: rule.cleanupPolicy
                    )
                )
            }
        }
        return items.sorted { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    func scanFixedRoots(rule: CleanupRule, now: Date) throws -> [CleanupItem] {
        try rule.locations.compactMap { location in
            try Task.checkCancellation()
            guard fileManager.fileExists(atPath: location.path) else {
                return nil
            }
            let values = try location.resourceValues(forKeys: Self.resourceKeys)
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                return nil
            }
            return CleanupItem(
                id: location.path,
                providerID: rule.id,
                stableIdentity: location.standardizedFileURL.path,
                displayName: location.lastPathComponent,
                url: location,
                discoveredAt: now,
                modifiedAt: values.contentModificationDate,
                resourceIdentifier: Self.resourceIdentifier(for: location, fileManager: fileManager),
                allocatedSize: try Self.allocatedSize(of: location, fileManager: fileManager),
                cleanupPolicy: rule.cleanupPolicy
            )
        }
        .filter { $0.allocatedSize > 0 }
        .sorted { $0.allocatedSize > $1.allocatedSize }
    }

    /// Discovers each declared root's immediate child *directories* as
    /// distinct candidates (for example one item per browser profile),
    /// rather than treating the whole root as a single lump-sum candidate.
    /// Any child whose name (case-insensitively) appears in `excludedNames`
    /// is never returned, even if present.
    func scanCacheRootChildren(
        rule: CleanupRule,
        excludedNames: Set<String>,
        now: Date
    ) throws -> [CleanupItem] {
        var items: [CleanupItem] = []
        for root in rule.locations where fileManager.fileExists(atPath: root.path) {
            try Task.checkCancellation()
            let children = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(Self.resourceKeys),
                options: [.skipsHiddenFiles]
            )
            for child in children {
                try Task.checkCancellation()
                guard !excludedNames.contains(child.lastPathComponent.lowercased()) else {
                    continue
                }
                guard let values = try? child.resourceValues(forKeys: Self.resourceKeys),
                      values.isDirectory == true,
                      values.isSymbolicLink != true else {
                    continue
                }
                let size = try Self.allocatedSize(of: child, fileManager: fileManager)
                guard size > 0 else {
                    continue
                }
                items.append(
                    CleanupItem(
                        id: child.path,
                        providerID: rule.id,
                        stableIdentity: child.standardizedFileURL.path,
                        displayName: "\(root.lastPathComponent) — \(child.lastPathComponent)",
                        url: child,
                        discoveredAt: now,
                        modifiedAt: values.contentModificationDate,
                        resourceIdentifier: Self.resourceIdentifier(for: child, fileManager: fileManager),
                        allocatedSize: size,
                        cleanupPolicy: rule.cleanupPolicy
                    )
                )
            }
        }
        return items.sorted { $0.allocatedSize > $1.allocatedSize }
    }

    func validatedURL(
        for item: CleanupItem,
        rule: CleanupRule,
        expected: ExpectedResource
    ) throws -> URL {
        guard item.providerID == rule.id,
              item.cleanupPolicy == rule.cleanupPolicy,
              let url = item.url,
              item.stableIdentity == url.standardizedFileURL.path else {
            throw CleanupValidationError.providerMismatch
        }
        try Self.validateResource(
            item: item,
            url: url,
            rule: rule,
            expected: expected,
            fileManager: fileManager
        )
        return url
    }

    func executeFilesystemPlan(
        _ plan: CleanupExecutionPlan,
        rule: CleanupRule,
        expected: ExpectedResource
    ) async -> CleanupReport {
        if let blocked = await runningApplicationBlock(rule: rule, items: plan.items) {
            return CleanupReport(outcomes: blocked)
        }
        let excludedNames: Set<String>
        if case .cacheRootChild(let names) = expected {
            excludedNames = names
        } else {
            excludedNames = []
        }
        var outcomes: [CleanupItemOutcome] = []
        for (index, item) in plan.items.enumerated() {
            if Task.isCancelled {
                outcomes.append(contentsOf: plan.items[index...].map(cancelled))
                break
            }
            do {
                let url = try validatedURL(for: item, rule: rule, expected: expected)
                switch item.cleanupPolicy {
                case .permanentDelete:
                    try fileManager.removeItem(at: url)
                    outcomes.append(cleaned(item))
                case .permanentDeleteContents:
                    try deleteValidatedContents(
                        of: url,
                        rule: rule,
                        discoveredAt: item.discoveredAt,
                        excludedNames: excludedNames
                    )
                    outcomes.append(cleaned(item))
                case .moveToTrash:
                    try fileTrasher.trashItem(at: url)
                    outcomes.append(outcome(item, status: .movedToTrash))
                case .unavailable, .deleteSimulator, .externalCommand:
                    outcomes.append(failed(item, message: "The item’s cleanup policy does not match this provider."))
                }
            } catch let error as CleanupValidationError {
                outcomes.append(
                    outcome(item, status: .skippedChanged, message: error.localizedDescription)
                )
            } catch is CancellationError {
                outcomes.append(cancelled(item))
            } catch {
                let presentation = UserFacingError.cleanup(error, categoryName: rule.name)
                outcomes.append(failed(
                    item,
                    message: presentation.alertMessage,
                    technicalDetails: presentation.technicalDetails
                ))
            }
        }
        return CleanupReport(outcomes: outcomes)
    }

    static func validateResource(
        item: CleanupItem,
        url: URL,
        rule: CleanupRule,
        expected: ExpectedResource,
        fileManager: FileManager
    ) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: resourceKeys)
        } catch {
            throw CleanupValidationError.missing
        }
        guard values.isSymbolicLink != true, rule.contains(url) else {
            throw CleanupValidationError.unsafePath
        }
        if case .cacheRootChild(let excludedNames) = expected,
           excludedNames.contains(url.lastPathComponent.lowercased()) {
            throw CleanupValidationError.sensitiveDataProtected
        }
        let currentModifiedAt: Date?
        if case .childDirectoryActivity = expected {
            currentModifiedAt = try boundedActivityDate(
                for: url,
                fallback: values.contentModificationDate,
                fileManager: fileManager
            )
        } else {
            currentModifiedAt = values.contentModificationDate
        }
        guard item.resourceIdentifier == resourceIdentifier(for: url, fileManager: fileManager),
              datesMatch(item.modifiedAt, currentModifiedAt) else {
            throw CleanupValidationError.changed
        }
        switch expected {
        case .regularFile(let extensions):
            guard values.isRegularFile == true else {
                throw CleanupValidationError.providerMismatch
            }
            if let extensions, !extensions.contains(url.pathExtension.lowercased()) {
                throw CleanupValidationError.providerMismatch
            }
        case .directory, .childDirectoryActivity:
            guard values.isDirectory == true else {
                throw CleanupValidationError.providerMismatch
            }
        case .exactRoot:
            guard values.isDirectory == true else {
                throw CleanupValidationError.providerMismatch
            }
            let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard rule.locations.contains(where: {
                $0.standardizedFileURL.resolvingSymlinksInPath().path == candidate
            }) else {
                throw CleanupValidationError.unsafePath
            }
        case .cacheRootChild:
            guard values.isDirectory == true else {
                throw CleanupValidationError.providerMismatch
            }
            let candidateParent = url.standardizedFileURL
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .path
            guard rule.locations.contains(where: {
                $0.standardizedFileURL.resolvingSymlinksInPath().path == candidateParent
            }) else {
                throw CleanupValidationError.unsafePath
            }
        }
    }

    static func allocatedSize(of url: URL, fileManager: FileManager) throws -> Int64 {
        let values = try url.resourceValues(forKeys: resourceKeys)
        if values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            try Task.checkCancellation()
            guard let childValues = try? child.resourceValues(forKeys: resourceKeys) else {
                continue
            }
            if childValues.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
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

    static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .contentModificationDateKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey
    ]

    static func resourceIdentifier(for url: URL, fileManager: FileManager) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return "\(device.uint64Value):\(file.uint64Value)"
    }

    private func cutoffDate(days: Int, now: Date) throws -> Date {
        guard days >= 0 else {
            throw CleanupProviderError.invalidRetentionDays
        }
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else {
            throw CleanupProviderError.couldNotCalculateCutoff
        }
        return cutoff
    }

    private static func boundedActivityDate(
        for root: URL,
        fallback: Date?,
        fileManager: FileManager
    ) throws -> Date? {
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try children.reduce(fallback) { newest, child in
            let name = child.lastPathComponent
            guard name == "Build" || name.hasPrefix("Index") else {
                return newest
            }
            let values = try child.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values.isDirectory == true, let date = values.contentModificationDate else {
                return newest
            }
            return max(newest ?? .distantPast, date)
        }
    }

    private func makeItem(
        url: URL,
        values: URLResourceValues,
        modifiedAt: Date,
        eligibilityCutoff: Date,
        rule: CleanupRule,
        now: Date
    ) -> CleanupItem {
        CleanupItem(
            id: url.path,
            providerID: rule.id,
            stableIdentity: url.standardizedFileURL.path,
            displayName: url.lastPathComponent,
            url: url,
            discoveredAt: now,
            modifiedAt: modifiedAt,
            eligibilityCutoff: eligibilityCutoff,
            resourceIdentifier: Self.resourceIdentifier(for: url, fileManager: fileManager),
            allocatedSize: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0),
            cleanupPolicy: rule.cleanupPolicy,
            notice: nil,
            originatingApplication: Self.originatingApplication(for: url, rule: rule)
        )
    }

    /// Returns the name of the immediate subdirectory of a declared root
    /// that contains `url`, when there is one (for example "Homebrew" for
    /// `~/Library/Logs/Homebrew/install.log"). Returns `nil` for items that
    /// sit directly inside a root, since guessing an origin for those would
    /// not be safe.
    private static func originatingApplication(for url: URL, rule: CleanupRule) -> String? {
        let candidate = url.standardizedFileURL.path
        for location in rule.locations {
            let root = location.standardizedFileURL.path
            guard candidate.hasPrefix(root + "/") else {
                continue
            }
            let relative = candidate.dropFirst(root.count + 1)
            let components = relative.split(separator: "/")
            guard components.count > 1, let first = components.first else {
                return nil
            }
            return String(first)
        }
        return nil
    }

    private func runningApplicationBlock(
        rule: CleanupRule,
        items: [CleanupItem]
    ) async -> [CleanupItemOutcome]? {
        let applications = await runningApplicationChecker.runningApplicationNames(
            bundleIdentifiers: rule.affectedApplicationBundleIdentifiers,
            names: rule.affectedApplicationNames
        )
        guard !applications.isEmpty else {
            return nil
        }
        let names = applications.sorted().joined(separator: ", ")
        return items.map { failed($0, message: "Quit \(names), rescan, and try again.") }
    }

    private func deleteValidatedContents(
        of root: URL,
        rule: CleanupRule,
        discoveredAt: Date,
        excludedNames: Set<String> = []
    ) throws {
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey],
            options: []
        )
        for child in children {
            try Task.checkCancellation()
            try validateTree(at: child, under: rule, discoveredAt: discoveredAt, excludedNames: excludedNames)
        }
        for child in children {
            try Task.checkCancellation()
            try fileManager.removeItem(at: child)
        }
    }

    private func validateTree(
        at url: URL,
        under rule: CleanupRule,
        discoveredAt: Date,
        excludedNames: Set<String> = []
    ) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey]
        let values = try url.resourceValues(forKeys: keys)
        guard rule.contains(url), values.isSymbolicLink != true else {
            throw CleanupValidationError.unsafePath
        }
        guard !excludedNames.contains(url.lastPathComponent.lowercased()) else {
            throw CleanupValidationError.sensitiveDataProtected
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
            try Task.checkCancellation()
            let childValues = try child.resourceValues(forKeys: keys)
            guard rule.contains(child), childValues.isSymbolicLink != true else {
                throw CleanupValidationError.unsafePath
            }
            guard !excludedNames.contains(child.lastPathComponent.lowercased()) else {
                throw CleanupValidationError.sensitiveDataProtected
            }
            if let modifiedAt = childValues.contentModificationDate,
               modifiedAt > discoveredAt.addingTimeInterval(0.001) {
                throw CleanupValidationError.changed
            }
        }
    }

    private static func datesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            abs(lhs.timeIntervalSince(rhs)) < 0.001
        default:
            false
        }
    }
}

struct SimulatorDevice: Decodable, Sendable {
    let name: String
    let udid: String
    let isAvailable: Bool
    /// CoreSimulator's reported device state (for example "Shutdown",
    /// "Booted", "Booting", "Creating", or "Shutting Down"). Older JSON
    /// fixtures may omit this field entirely; a missing state is treated as
    /// "not actively booted" rather than blocking cleanup, since real
    /// `simctl` output always includes it.
    let state: String?

    var isActive: Bool {
        guard let state else {
            return false
        }
        return state != "Shutdown"
    }
}

private struct SimulatorListing: Decodable {
    let devices: [String: [SimulatorDevice]]

    static func decodeUnavailable(from result: CommandResult) throws -> [SimulatorDevice] {
        try decodeAll(from: result).filter { !$0.isAvailable }
    }

    static func decodeAll(from result: CommandResult) throws -> [SimulatorDevice] {
        guard result.terminationStatus == 0 else {
            let error = String(decoding: result.standardError, as: UTF8.self)
            let output = String(decoding: result.standardOutput, as: UTF8.self)
            throw CleanupProviderError.commandFailed(
                (error.isEmpty ? output : error).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try JSONDecoder().decode(Self.self, from: result.standardOutput)
            .devices.values.flatMap { $0 }
    }
}

enum CleanupValidationError: LocalizedError {
    case missing
    case unsafePath
    case changed
    case providerMismatch
    case sensitiveDataProtected

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
        case .sensitiveDataProtected:
            "This item contains data SpaceMender never deletes, such as cookies, history, "
                + "sessions, extensions, or profile data, so it was skipped."
        }
    }
}

enum CleanupProviderError: LocalizedError {
    case providerNotRegistered(String)
    case invalidRetentionDays
    case couldNotCalculateCutoff
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .providerNotRegistered(let id):
            "No cleanup provider is registered for \(id)."
        case .invalidRetentionDays:
            "Retention days cannot be negative."
        case .couldNotCalculateCutoff:
            "SpaceMender could not calculate the cleanup cutoff date."
        case .commandFailed(let message):
            message.isEmpty ? "A cleanup tool could not inspect its data." : "The cleanup tool could not complete the operation."
        }
    }
}

private func cleaned(_ item: CleanupItem) -> CleanupItemOutcome {
    outcome(item, status: .cleaned)
}

private func failed(
    _ item: CleanupItem,
    message: String,
    technicalDetails: String? = nil
) -> CleanupItemOutcome {
    outcome(
        item,
        status: .failed,
        message: message,
        technicalDetails: technicalDetails
    )
}

private func cancelled(_ item: CleanupItem) -> CleanupItemOutcome {
    outcome(item, status: .cancelled, message: "Cleanup was cancelled.")
}

private func commandOutcome(
    _ item: CleanupItem,
    error: Error,
    categoryName: String
) -> CleanupItemOutcome {
    if error is CancellationError {
        return cancelled(item)
    }
    if let processError = error as? ProcessRunnerError,
       case .cancelled = processError {
        return cancelled(item)
    }
    let presentation = UserFacingError.cleanup(error, categoryName: categoryName)
    return failed(
        item,
        message: presentation.alertMessage,
        technicalDetails: presentation.technicalDetails
    )
}

private func requireSuccessfulCommand(_ result: CommandResult) throws {
    guard result.terminationStatus == 0 else {
        let standardError = String(decoding: result.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let standardOutput = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw CleanupProviderError.commandFailed(
            standardError.isEmpty ? standardOutput : standardError
        )
    }
}

private func outcome(
    _ item: CleanupItem,
    status: CleanupOutcomeStatus,
    message: String? = nil,
    technicalDetails: String? = nil
) -> CleanupItemOutcome {
    CleanupItemOutcome(
        itemID: item.id,
        displayName: item.displayName,
        status: status,
        message: message,
        technicalDetails: technicalDetails
    )
}
