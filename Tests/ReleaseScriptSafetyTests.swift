import Foundation
import Testing

struct ReleaseScriptSafetyTests {
    @Test
    func customReleaseRootRequiresMarkerAndPreservesUnrelatedFiles() throws {
        let fileManager = FileManager.default
        let repository = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = fileManager.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let unrelated = root.appending(path: "keep-me.txt")
        try Data("important".utf8).write(to: unrelated)

        let rejected = runPrepare(repository: repository, releaseRoot: root)
        #expect(rejected.status != 0)
        #expect(fileManager.fileExists(atPath: unrelated.path))

        try Data().write(to: root.appending(path: ".spacemender-release-root"))
        let ownedArchive = root.appending(path: "SpaceMender.xcarchive", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: ownedArchive, withIntermediateDirectories: true)

        let accepted = runPrepare(repository: repository, releaseRoot: root)
        #expect(accepted.status == 0)
        #expect(fileManager.fileExists(atPath: unrelated.path))
        #expect(!fileManager.fileExists(atPath: ownedArchive.path))
        #expect(fileManager.fileExists(atPath: root.appending(path: "export").path))
    }

    private func runPrepare(repository: URL, releaseRoot: URL) -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [
            "-c",
            ". ./scripts/release-lib.sh; prepare_release_root"
        ]
        process.currentDirectoryURL = repository
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["SPACEMENDER_RELEASE_ROOT": releaseRoot.path]
        ) { _, new in new }
        process.standardOutput = output
        process.standardError = output
        try? process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
