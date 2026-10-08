import SwiftUI

@main
struct PengPengHeartbeatApp: App {
    private let runner = CoreNFCTagSessionRunner()

    var body: some Scene {
        WindowGroup {
            HeartbeatView(runner: runner)
        }
    }
}
