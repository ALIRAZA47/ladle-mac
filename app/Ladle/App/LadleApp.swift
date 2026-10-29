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
                menuBar.isInserted = newValue
                if AppModel.shared.settings.showInMenuBar != newValue {
                    AppModel.shared.settings.showInMenuBar = newValue
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
