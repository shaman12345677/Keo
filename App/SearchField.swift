import GameController
import SwiftUI

struct InventorySearchContainer<Content: View>: View {
    @Binding var query: String
    var prompt: String
    @ViewBuilder var content: () -> Content
    @FocusState private var focused: Bool
    @State private var hardwareKeyboard = GCKeyboard.coalesced != nil

    var body: some View {
        content()
            .safeAreaInset(edge: .top, spacing: 0) {
                searchBar
                    .background(Color(.systemBackground))
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if focused && hardwareKeyboard {
                    CzechSearchKeyboard(text: $query) {
                        focused = false
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
                hardwareKeyboard = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
                hardwareKeyboard = false
            }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $query)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

private struct CzechSearchKeyboard: View {
    @Binding var text: String
    var onDone: () -> Void
    @State private var shifted = false
    @State private var numbers = false

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 4) {
                    ForEach(line, id: \.self) { key in
                        keyButton(shifted ? key.uppercased() : key) {
                            insert(shifted ? key.uppercased() : key)
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                keyButton(numbers ? "ABC" : "123") {
                    numbers.toggle()
                    shifted = false
                }
                if !numbers {
                    keyButton(shifted ? "⇧" : "⬆") {
                        shifted.toggle()
                    }
                }
                keyButton("mezera") {
                    insert(" ")
                }
                keyButton("⌫") {
                    if !text.isEmpty { text.removeLast() }
                }
                keyButton("Hotovo", action: onDone)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Color(.secondarySystemBackground))
    }

    private var lines: [[String]] {
        if numbers {
            return [
                ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
                ["-", "/", ".", ","],
            ]
        }
        return [
            ["ě", "š", "č", "ř", "ž", "ý", "á", "í", "é"],
            ["q", "w", "e", "r", "t", "z", "u", "i", "o", "p"],
            ["a", "s", "d", "f", "g", "h", "j", "k", "l", "ů"],
            ["y", "x", "c", "v", "b", "n", "m"],
        ]
    }

    private func insert(_ value: String) {
        text.append(value)
        if shifted { shifted = false }
    }

    private func keyButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: title.count > 1 ? 15 : 18))
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
