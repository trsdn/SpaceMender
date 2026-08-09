import Foundation

protocol DefenderCodeSignatureChecking: Sendable {
    func isValid(auditToken: Data, requirement: String) -> Bool
}

struct DefenderClientAuthorizationPolicy: Sendable {
    let requirement: String?
    let signatureChecker: any DefenderCodeSignatureChecking

    func authorizes(auditToken: Data) -> Bool {
        guard !auditToken.isEmpty,
              let requirement,
              !requirement.isEmpty else {
            return false
        }
        return signatureChecker.isValid(
            auditToken: auditToken,
            requirement: requirement
        )
    }
}
