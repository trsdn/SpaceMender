import Foundation

@main
struct DefenderHelperMain {
    static func main() {
        let delegate = DefenderHelperListenerDelegate()
        let listener = NSXPCListener(machServiceName: DefenderHelperConstants.machServiceName)
        // This is the *only* place client authorization is enforced. Without a requirement the
        // helper refuses to run at all rather than accepting every caller as root — a missing or
        // empty key must stay fatal.
        guard let requirement = Bundle.main.object(
            forInfoDictionaryKey: "SpaceMenderAuthorizedClientRequirement"
        ) as? String,
        !requirement.isEmpty else {
            exit(EXIT_FAILURE)
        }
        // Foundation enforces this requirement against each peer's XPC audit
        // token before the delegate sees the connection.
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
