import Foundation

enum DefenderHelperConstants {
    static let machServiceName = "app.spacemender.SpaceMender.DefenderHelper"
    static let helperBundleIdentifier = "app.spacemender.SpaceMender.DefenderHelper"
    static let launchDaemonPlistName = "app.spacemender.SpaceMender.DefenderHelper.plist"
    static let protocolVersion = 1
    static let productionRoot = URL(
        filePath: "/Library/Application Support/Microsoft/Defender/wdavdiag",
        directoryHint: .isDirectory
    )
}

struct DefenderCandidateIdentity: Codable, Sendable, Equatable {
    let fileName: String
    let resourceIdentifier: String
    let modifiedAt: Date
    let discoveredAt: Date
    let cutoffDate: Date
}

enum DefenderHelperItemStatus: String, Codable, Sendable {
    case cleaned
    case skippedChanged
    case rejected
    case failed
}

struct DefenderHelperItemOutcome: Codable, Sendable {
    let fileName: String
    let status: DefenderHelperItemStatus
    let message: String?
}

struct DefenderHelperStatusResponse: Codable, Sendable {
    let protocolVersion: Int
    let authenticated: Bool
}

struct DefenderHelperCleanupRequest: Codable, Sendable {
    let protocolVersion: Int
    let candidates: [DefenderCandidateIdentity]
}

struct DefenderHelperCleanupResponse: Codable, Sendable {
    let outcomes: [DefenderHelperItemOutcome]
}

@objc protocol DefenderHelperXPCProtocol {
    func status(reply: @escaping (Data) -> Void)
    func removeDefenderDiagnostics(request: Data, reply: @escaping (Data) -> Void)
}

enum DefenderHelperCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}
