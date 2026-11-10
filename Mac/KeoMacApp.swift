import AppKit
import SwiftUI

struct InventoryActions {
    var open: () -> Void
    var export: () -> Void
    var canExport: Bool
}

private struct InventoryActionsKey: FocusedValueKey {
    typealias Value = InventoryActions
}

extension FocusedValues {
    var inventoryActions: InventoryActions? {
        get { self[InventoryActionsKey.self] }
        set { self[InventoryActionsKey.self] = newValue }
    }
}

final class KeoMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        ContinuityCameraSupport.registerServices()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ContinuityCameraSupport.registerServices()
        ContinuityCameraSupport.installMenuItemIfNeeded()
        // SwiftUI menu se skládá později — Continuity položku musíme doplnit opakovaně.
        for delay in [0.3, 0.8, 1.5, 3.0] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                ContinuityCameraSupport.installMenuItemIfNeeded()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ContinuityCameraSupport.registerServices()
        ContinuityCameraSupport.installMenuItemIfNeeded()
    }
}

@main
struct KeoMacApp: App {
    @NSApplicationDelegateAdaptor(KeoMacAppDelegate.self) private var appDelegate
    @StateObject private var store = InventoryStore()
    @StateObject private var scanner = MacScanner()

    var body: some Scene {
        WindowGroup("Keo4 inventura") {
            MacWindow()
                .environmentObject(store)
                .environmentObject(scanner)
                .onAppear {
                    ContinuityCameraSupport.installMenuItemIfNeeded()
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            MacCommands()
        }
    }
}

private struct MacCommands: Commands {
    @FocusedValue(\.inventoryActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Otevřít inventuru…") { actions?.open() }
                .keyboardShortcut("o")
                .disabled(actions == nil)
            Button("Exportovat…") { actions?.export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions?.canExport != true)
        }
    }
}
