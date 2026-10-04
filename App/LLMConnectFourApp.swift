import SwiftUI

@main
struct LLMConnectFourApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: DesignTokens.Window.minWidth, minHeight: DesignTokens.Window.minHeight)
        }
        .windowToolbarStyle(.unified)

        Window("Leaderboard", id: "leaderboard") {
            Text("Leaderboard")
                .frame(minWidth: 720, minHeight: 420)
        }

        Settings {
            Text("Settings")
                .frame(width: 480, height: 320)
        }
    }
}
