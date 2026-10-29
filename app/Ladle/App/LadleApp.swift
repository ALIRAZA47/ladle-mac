import LadleKit
import SwiftUI

@main
struct LadleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var menuBar = MenuBarVisibility.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { menuBar.isInserted },
            set: { newValue in
                guard newValue != menuBar.isInserted else { return }
                menuBar.isInserted = newValue
                // Removed from the menu bar by hand (⌘-drag): keep the setting in step, after
                // this scene update rather than during it.
                Task { @MainActor in
                    if AppModel.shared.settings.showInMenuBar != newValue {
                        AppModel.shared.settings.showInMenuBar = newValue
                    }
                }
            }
        )) {
            Themed { MenuBarView() }
                .environmentObject(AppModel.shared)
        } label: {
            MenuBarLabel(model: AppModel.shared)
        }
        .menuBarExtraStyle(.window)
        .commands {
            LadleCommands(model: AppModel.shared, updates: AppModel.shared.updates)
        }
    }
}
