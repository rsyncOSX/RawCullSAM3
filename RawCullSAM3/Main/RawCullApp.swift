//
//  RawCullApp.swift
//  RawCullSAM3
//
//  Created by Thomas Evensen on 19/01/2026.
//

import OSLog
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_: Notification) {}
}

#if !SAM3_MASK_BUILDER
    @main
    struct RawCullSAM3App: App {
        @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

        @State private var gridthumbnailviewmodel = GridThumbnailViewModel()
        @State private var viewModel = RawCullViewModel()

        var body: some Scene {
            Window("RawCullSAM3", id: "main-window") {
                RawCullMainView(viewModel: viewModel)
                    .background(.windowBackground)
                    .environment(gridthumbnailviewmodel)
                    .environment(viewModel)
                    .task {
                        await viewModel.applyStoredScoringSettings()
                    }
                    .onDisappear {
                        // Quit the app when the main window is closed
                        performCleanupTask()
                        NSApplication.shared.terminate(nil)
                    }
            }
            .windowToolbarStyle(.unified)
            .commands {
                SidebarCommands()

                MenuCommands()
            }

            Settings {
                SettingsView()
                    .environment(viewModel)
            }
        }

        private func performCleanupTask() {
            Logger.process.debugMessageOnly("RawCullSAM3App: performCleanupTask(), shutting down, doing clean up")
            viewModel.stopActiveSecurityScopedAccess()
        }
    }
#endif
