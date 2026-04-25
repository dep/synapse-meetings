import SwiftUI

@main
struct SynapseMeetingsApp: App {
    @StateObject private var appState: AppState = {
        // Run any one-time data migrations from a previous bundle ID
        // before AppState wires up its services.
        AppMigration.runIfNeeded()
        return AppState()
    }()
    @StateObject private var updater = UpdaterController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 980, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording") {
                    appState.requestNewRecording()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
