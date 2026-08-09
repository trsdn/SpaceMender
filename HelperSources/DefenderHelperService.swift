import Foundation
import os

final class DefenderHelperService: NSObject, DefenderHelperXPCProtocol {
    private let validator: DefenderArchiveValidator
    private let logger = Logger(
        subsystem: DefenderHelperConstants.helperBundleIdentifier,
        category: "cleanup"
    )

    init(validator: DefenderArchiveValidator = DefenderArchiveValidator()) {
        self.validator = validator
    }

    func status(reply: @escaping (Data) -> Void) {
        let response = DefenderHelperStatusResponse(
            protocolVersion: DefenderHelperConstants.protocolVersion,
            authenticated: true
        )
        reply((try? DefenderHelperCoding.encode(response)) ?? Data())
    }

    func removeDefenderDiagnostics(request: Data, reply: @escaping (Data) -> Void) {
        let response: DefenderHelperCleanupResponse
        do {
            let request = try DefenderHelperCoding.decode(
                DefenderHelperCleanupRequest.self,
                from: request
            )
            guard request.protocolVersion == DefenderHelperConstants.protocolVersion else {
                let emptyResponse = DefenderHelperCleanupResponse(outcomes: [])
                reply((try? DefenderHelperCoding.encode(emptyResponse)) ?? Data())
                return
            }

            var seen = Set<String>()
            let outcomes = request.candidates.map { candidate in
                guard seen.insert(candidate.fileName).inserted else {
                    return DefenderHelperItemOutcome(
                        fileName: candidate.fileName,
                        status: .rejected,
                        message: "Duplicate candidate identity."
                    )
                }
                do {
                    try validator.remove(candidate)
                    return DefenderHelperItemOutcome(
                        fileName: candidate.fileName,
                        status: .cleaned,
                        message: nil
                    )
                } catch let error as DefenderArchiveValidationError {
                    let status: DefenderHelperItemStatus = switch error {
                    case .changed, .tooRecent, .missing:
                        .skippedChanged
                    case .couldNotDelete:
                        .failed
                    default:
                        .rejected
                    }
                    return DefenderHelperItemOutcome(
                        fileName: candidate.fileName,
                        status: status,
                        message: error.outcomeMessage
                    )
                } catch {
                    return DefenderHelperItemOutcome(
                        fileName: candidate.fileName,
                        status: .failed,
                        message: "The helper could not process the archive."
                    )
                }
            }
            response = DefenderHelperCleanupResponse(outcomes: outcomes)
            let cleanedCount = outcomes.filter { $0.status == .cleaned }.count
            logger.info(
                "Processed \(outcomes.count, privacy: .public) Defender archive identities; cleaned \(cleanedCount, privacy: .public)"
            )
        } catch {
            logger.error("Rejected malformed Defender helper request")
            response = DefenderHelperCleanupResponse(outcomes: [])
        }
        reply((try? DefenderHelperCoding.encode(response)) ?? Data())
    }
}
