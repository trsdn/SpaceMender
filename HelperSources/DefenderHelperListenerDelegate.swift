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

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: DefenderHelperXPCProtocol.self)
        newConnection.exportedObject = serviceFactory()
        newConnection.resume()
        logger.info("Accepted client after audit-token code-signing validation")
        return true
    }
}
