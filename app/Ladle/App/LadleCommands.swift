import AppKit
import LadleKit
import SwiftUI

/// The menus, with the shortcuts from SPEC "Keyboard shortcuts". Space is handled by the list itself,
/// so it never steals a space typed into a text field. Items that change with the app's state are
/// small views that observe it, which is how SwiftUI keeps menu items up to date.
struct LadleCommands: Commands {
    let model: AppModel
    let updates: UpdateController

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showSettingsWindow?() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton(updates: updates)
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Downloads…") { model.openAddSheet() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Paste a Link or Search") { model.focusLinkBar() }
                .keyboardShortcut("k", modifiers: .command)
        }
        CommandMenu("Downloads") {
            DownloadsMenuItems(model: model)
        }
        CommandGroup(replacing: .help) {
            Button("Ladle Help") { NSWorkspace.shared.open(LadleLinks.docsHome) }
            Button("Set Up Your Browser") { NSWorkspace.shared.open(LadleLinks.setUpBrowser) }
            Button("Keyboard Shortcuts") { NSWorkspace.shared.open(LadleLinks.keyboardShortcuts) }
            Button("Menu Bar, Dock and Notifications") { NSWorkspace.shared.open(LadleLinks.menuBarDockAndNotifications) }
            Button("A Download Failed") { NSWorkspace.shared.open(LadleLinks.downloadFailed) }
            Button("A Download Won’t Resume") { NSWorkspace.shared.open(LadleLinks.wontResume) }
            Divider()
            Button("Release Notes") { NSWorkspace.shared.open(LadleLinks.changelog) }
            Button("Privacy") { NSWorkspace.shared.open(LadleLinks.privacy) }
            Button("Report an Issue") { NSWorkspace.shared.open(LadleLinks.support) }
        }
    }
}

private struct CheckForUpdatesButton: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheckForUpdates)
    }
}

private struct DownloadsMenuItems: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let item = model.selectedItem
        Button(pauseTitle(item)) { model.toggleSelected() }
            .disabled(item == nil || item?.status == .completed)
        Button(model.pauseAllPauses ? "Pause All" : "Resume All") { model.togglePauseAll() }
            .keyboardShortcut("p", modifiers: [.command, .option])
        Divider()
        Button("Retry") {
            if let item { model.perform(ItemPresentation.primaryAction(item), on: item) }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(item?.status != .failed)
        Button("Open") {
            if let item { model.open(item) }
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(item?.status != .completed)
        Button("Show in Finder") {
            if let item { model.reveal(item) }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(item == nil)
        Button("Copy Link") {
            if let item { model.copyLink(item) }
        }
        .disabled(item == nil)
        Divider()
        Button("Remove from List") {
            if let item { model.remove(item.id) }
        }
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(item == nil || model.isEditingText)
    }

    private func pauseTitle(_ item: DownloadItem?) -> String {
        switch item?.status {
        case .paused?: return item?.neverStarted == true ? "Start" : "Resume"
        case .failed?: return "Retry"
        default: return "Pause"
        }
    }
}
