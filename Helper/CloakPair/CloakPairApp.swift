import SwiftUI

@main
struct CloakPairApp: App {
    var body: some Scene {
        WindowGroup("Cloak Pair") {
            PairWindow()
                .frame(minWidth: 620, minHeight: 620)
        }
        .windowResizability(.contentSize)
    }
}
