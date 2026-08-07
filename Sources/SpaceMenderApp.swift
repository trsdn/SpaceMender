import SwiftUI

@main
struct SpaceMenderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 620)
    }
}
