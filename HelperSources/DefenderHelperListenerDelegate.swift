import Foundation
import os

final class DefenderHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let serviceFactory: () -> DefenderHelperXPCProtocol
    private let logger = Logger(
        subsystem: DefenderHelperConstants.helperBundleIdentifier,
        category: "authentication"
    )

    init(
        serviceFactory: @escaping () -> DefenderHelperXPCProtocol = { DefenderHelperService() }
    ) {
        self.serviceFactory = serviceFactory
    }

    /// Client authorization is **not** performed here. `DefenderHelperMain` installs the
    /// `SpaceMenderAuthorizedClientRequirement` code-signing requirement on the listener, and
    /// Foundation evaluates it against the peer's XPC audit token before this delegate is ever
    /// consulted — an unauthorized peer never reaches this method. Adding a check here would be
    /// redundant; weakening the listener requirement would be the actual regression.
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: DefenderHelperXPCProtocol.self)
        newConnection.exportedObject = serviceFactory()
        newConnection.resume()
        logger.info("Accepted client already validated by the listener code-signing requirement")
        return true
    }
}
