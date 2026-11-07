import CoreImage.CIFilterBuiltins
import SwiftUI

/// V simulátoru není kamera. Místo ní je štítek, aby šel udělat snímek skenování.
struct SimulatorScanBackdrop: View {
    private let payload = "1022\nTiskárna\n14.04.2020\nV:2"

    var body: some View {
        ZStack {
            Color(red: 0.83, green: 0.80, blue: 0.75)
            VStack(spacing: 4) {
                Text("Inv. č. 1022")
                    .font(.title2.weight(.semibold))
                Text("Tiskárna")
                    .font(.title3)
            }
            .offset(y: -176)
            RoundedRectangle(cornerRadius: 18)
                .fill(.white)
                .frame(width: 248, height: 248)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            Image(uiImage: Self.code(payload))
                .interpolation(.none)
                .resizable()
                .frame(width: 196, height: 196)
            Text("14. 4. 2020")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.white, in: Capsule())
                .offset(y: 168)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func code(_ text: String) -> UIImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        let scaled = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 16, y: 16))
        let image = CIContext().createCGImage(scaled, from: scaled.extent)!
        return UIImage(cgImage: image)
    }
}
