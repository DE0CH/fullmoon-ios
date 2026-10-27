//
//  fullmoonApp.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/4/24.
//

import SwiftUI
import UserNotifications

@main
struct fullmoonApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #else
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) var appDelegate
    #endif
    @StateObject var appManager = AppManager()
    @State var llm = LLMEvaluator()
    @State var downloader = ModelDownloader.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(for: [Thread.self, Message.self])
                .environmentObject(appManager)
                .environment(llm)
                .environment(downloader)
                #if os(macOS) || os(visionOS)
                .frame(minWidth: 640, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
                #if os(macOS)
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                }
                #endif
                #endif
        }
        #if os(visionOS)
        .windowResizability(.contentSize)
        #endif
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Show Main Window") {
                    if let mainWindow = NSApp.windows.first {
                        mainWindow.makeKeyAndOrderFront(nil)
                    }
                }
            }
        }
        #endif
    }
}

#if os(iOS)
/// iOS relaunches the app in the background when the model download has news; the downloader's session picks the
/// events up and calls this handler once they are handled.
class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated {
            ModelDownloader.shared.backgroundCompletionHandler = completionHandler
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner]
    }
}
#endif

#if os(macOS)
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var closedWindowsStack = [NSWindow]()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainWindow = NSApp.windows.first
        mainWindow?.delegate = self
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // if there’s a recently closed window, bring that back
        if let lastClosed = closedWindowsStack.popLast() {
            lastClosed.makeKeyAndOrderFront(self)
        } else {
            // otherwise, un-minimize any minimized windows
            for window in sender.windows where window.isMiniaturized {
                window.deminiaturize(nil)
            }
        }
        return false
    }
    
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            closedWindowsStack.append(window)
        }
    }
}
#endif
