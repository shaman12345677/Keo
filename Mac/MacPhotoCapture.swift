import AppKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MacCardPhotos: View {
    @EnvironmentObject private var store: InventoryStore
    let cardID: String
    @State private var pickerItem: PhotosPickerItem?
    @State private var preview: SessionPhoto?
    @State private var captureStatus: String?
    @State private var captureError: String?
    @State private var captureSession: ContinuityTakePhotoSession?

    var body: some View {
        let photos = store.photos(forCardID: cardID)
        VStack(alignment: .leading, spacing: 10) {
            Text("Fotografie")
                .font(.headline)
            if photos.isEmpty {
                Text("Zatím bez fotografie")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(photos) { photo in
                            if let data = store.photoData(for: photo), let image = NSImage(data: data) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 112, height: 112)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .onTapGesture { preview = photo }
                                    .contextMenu {
                                        Button("Smazat", role: .destructive) {
                                            store.removePhoto(photo)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Label("Z alba", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
                .disabled(captureSession != nil)
                if captureSession == nil {
                    Button {
                        startContinuityCapture()
                    } label: {
                        Label("Vyfotit na iPhonu", systemImage: "iphone")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(role: .destructive) {
                        captureSession?.cancel()
                        captureSession = nil
                        captureStatus = nil
                        captureError = "Zrušeno."
                    } label: {
                        Label("Zrušit focení", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                }
            }
            if let captureStatus {
                Text(captureStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let captureError {
                Text(captureError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("Vyfotit na iPhonu otevře foťák přímo na telefonu (Continuity). iPhone musí být poblíž a odemčený.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let file = try? await item.loadTransferable(type: PhotoFile.self) {
                    await MainActor.run {
                        store.addPhoto(cardID: cardID, imageData: file.data)
                        pickerItem = nil
                    }
                }
            }
        }
        .sheet(item: $preview) { photo in
            if let data = store.photoData(for: photo), let image = NSImage(data: data) {
                VStack(spacing: 12) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 720, maxHeight: 720)
                    HStack {
                        Button("Smazat", role: .destructive) {
                            store.removePhoto(photo)
                            preview = nil
                        }
                        Spacer()
                        Button("Zavřít") { preview = nil }
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .padding()
            }
        }
        .onDisappear {
            captureSession?.cancel()
            captureSession = nil
        }
    }

    private func startContinuityCapture() {
        captureError = nil
        captureStatus = "Připravuji Continuity Camera…"
        captureSession?.cancel()

        let session = ContinuityTakePhotoSession(
            onStatus: { message in
                DispatchQueue.main.async { captureStatus = message }
            },
            onImage: { data in
                DispatchQueue.main.async {
                    store.addPhoto(cardID: cardID, imageData: data)
                    captureStatus = "Fotografie uložena."
                    captureError = nil
                    captureSession = nil
                }
            },
            onFailed: { message in
                DispatchQueue.main.async {
                    captureError = message
                    captureStatus = nil
                    captureSession = nil
                }
            }
        )
        captureSession = session
        session.start()
    }
}

private struct PhotoFile: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .jpeg) { PhotoFile(data: $0) }
        DataRepresentation(importedContentType: .heic) { PhotoFile(data: $0) }
        DataRepresentation(importedContentType: .png) { PhotoFile(data: $0) }
        DataRepresentation(importedContentType: .image) { PhotoFile(data: $0) }
    }
}
