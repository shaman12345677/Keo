import SwiftUI

@main
struct KeoApp: App {
    @StateObject private var store = InventoryStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .onOpenURL { url in
                    store.importFile(at: url)
                }
        }
    }
}
