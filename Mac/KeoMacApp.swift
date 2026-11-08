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

@main
struct KeoMacApp: App {
    @StateObject private var store = InventoryStore()
    @StateObject private var scanner = MacScanner()

    var body: some Scene {
        WindowGroup("Keo4 inventura") {
            MacWindow()
                .environmentObject(store)
                .environmentObject(scanner)
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
