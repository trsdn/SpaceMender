import Foundation
import Testing
@testable import SpaceMender

struct DefenderHelperContractTests {
    @Test
    func cleanupRequestRoundTripsCandidateIdentitiesAndMillisecondDates() throws {
        let candidates = [
            DefenderCandidateIdentity(
                fileName: "first.zip",
                resourceIdentifier: "1:2",
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000.123),
                discoveredAt: Date(timeIntervalSince1970: 1_800_000_000.456),
                cutoffDate: Date(timeIntervalSince1970: 1_750_000_000.789)
            ),
            DefenderCandidateIdentity(
                fileName: "second.zip",
                resourceIdentifier: "3:4",
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_100.321),
                discoveredAt: Date(timeIntervalSince1970: 1_800_000_100.654),
                cutoffDate: Date(timeIntervalSince1970: 1_750_000_100.987)
            )
        ]
        let request = DefenderHelperCleanupRequest(
            protocolVersion: DefenderHelperConstants.protocolVersion,
            candidates: candidates
        )

        let decoded = try DefenderHelperCoding.decode(
            DefenderHelperCleanupRequest.self,
            from: DefenderHelperCoding.encode(request)
        )

        #expect(decoded.protocolVersion == request.protocolVersion)
        #expect(decoded.candidates.count == candidates.count)
        for (decodedCandidate, originalCandidate) in zip(decoded.candidates, candidates) {
            #expect(decodedCandidate.fileName == originalCandidate.fileName)
            #expect(decodedCandidate.resourceIdentifier == originalCandidate.resourceIdentifier)
            #expect(abs(decodedCandidate.modifiedAt.timeIntervalSince(originalCandidate.modifiedAt)) < 0.001)
            #expect(abs(decodedCandidate.discoveredAt.timeIntervalSince(originalCandidate.discoveredAt)) < 0.001)
            #expect(abs(decodedCandidate.cutoffDate.timeIntervalSince(originalCandidate.cutoffDate)) < 0.001)
        }
    }

    @Test
    func statusResponseRoundTripsAuthenticatedProtocol() throws {
        let response = DefenderHelperStatusResponse(
            protocolVersion: DefenderHelperConstants.protocolVersion,
            authenticated: true
        )

        let decoded = try DefenderHelperCoding.decode(
            DefenderHelperStatusResponse.self,
            from: DefenderHelperCoding.encode(response)
        )

        #expect(decoded.protocolVersion == response.protocolVersion)
        #expect(decoded.authenticated == response.authenticated)
    }

    @Test
    func cleanupResponseRoundTripsOutcomeStatusesAndMessages() throws {
        let response = DefenderHelperCleanupResponse(
            outcomes: [
                DefenderHelperItemOutcome(fileName: "cleaned.zip", status: .cleaned, message: nil),
                DefenderHelperItemOutcome(
                    fileName: "changed.zip",
                    status: .skippedChanged,
                    message: "The archive changed after the scan."
                ),
                DefenderHelperItemOutcome(
                    fileName: "rejected.zip",
                    status: .rejected,
                    message: "The archive failed the helper safety checks."
                ),
                DefenderHelperItemOutcome(
                    fileName: "failed.zip",
                    status: .failed,
                    message: "The helper could not remove the validated archive."
                )
            ]
        )

        let decoded = try DefenderHelperCoding.decode(
            DefenderHelperCleanupResponse.self,
            from: DefenderHelperCoding.encode(response)
        )

        #expect(decoded.outcomes.count == response.outcomes.count)
        for (decodedOutcome, originalOutcome) in zip(decoded.outcomes, response.outcomes) {
            #expect(decodedOutcome.fileName == originalOutcome.fileName)
            #expect(decodedOutcome.status == originalOutcome.status)
            #expect(decodedOutcome.message == originalOutcome.message)
        }
    }

    @Test
    func malformedRequestPayloadFailsDecoding() {
        #expect(throws: DecodingError.self) {
            _ = try DefenderHelperCoding.decode(
                DefenderHelperCleanupRequest.self,
                from: Data("{not valid json}".utf8)
            )
        }
    }

    @Test
    func malformedResponsePayloadFailsDecoding() {
        #expect(throws: DecodingError.self) {
            _ = try DefenderHelperCoding.decode(
                DefenderHelperCleanupResponse.self,
                from: Data("[]".utf8)
            )
        }
    }
}
