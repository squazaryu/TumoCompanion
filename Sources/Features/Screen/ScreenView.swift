import SwiftUI
import UIKit

struct ShareImage: Identifiable { let id = UUID(); let url: URL }

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A reusable 128×64 mirror. Home uses the same renderer as the full Remote
/// screen, so the preview never drifts from what the user will see after tapping it.
struct FlipperScreenCanvas: View {
    let pixels: [Bool]

    var body: some View {
        Canvas { ctx, size in
            let w = FlipperControl.screenW
            let h = FlipperControl.screenH
            let px = size.width / CGFloat(w)
            let py = size.height / CGFloat(h)

            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(red: 0.96, green: 0.55, blue: 0.06)))
            guard pixels.count >= w * h else { return }
            for y in 0..<h {
                for x in 0..<w where pixels[y * w + x] {
                    let rect = CGRect(x: CGFloat(x) * px,
                                      y: CGFloat(y) * py,
                                      width: px + 0.5,
                                      height: py + 0.5)
                    ctx.fill(Path(rect), with: .color(.black))
                }
            }
        }
        .aspectRatio(CGFloat(FlipperControl.screenW) / CGFloat(FlipperControl.screenH),
                     contentMode: .fit)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.accent.opacity(0.45), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }
}

private struct FlipperRemoteButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var diameter: CGFloat = 54

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(configuration.isPressed ? tint : .primary)
            .frame(width: diameter, height: diameter)
            .background {
                Circle()
                    .fill(Color(.secondarySystemBackground))
                    .overlay {
                        Circle()
                            .strokeBorder(tint.opacity(configuration.isPressed ? 0.65 : 0.18),
                                          lineWidth: configuration.isPressed ? 2 : 1)
                    }
            }
            .shadow(color: .black.opacity(configuration.isPressed ? 0.05 : 0.14),
                    radius: configuration.isPressed ? 2 : 5,
                    y: configuration.isPressed ? 1 : 3)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct FlipperBackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(configuration.isPressed ? Theme.accent : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Theme.accent.opacity(configuration.isPressed ? 0.65 : 0.2), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ScreenView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var control: FlipperControl
    @State private var shareItem: ShareImage?

    // Quick-launch for the Flipper's built-in apps. Launching an app and watching
    // it through the same live mirror keeps this destination useful beyond input.
    static let builtInApps: [(String, String)] = [
        ("Sub-GHz", "dot.radiowaves.right"),
        ("NFC", "wave.3.right"),
        ("125 kHz RFID", "key"),
        ("Infrared", "av.remote"),
        ("Bad USB", "cable.connector"),
        ("GPIO", "cpu")
    ]

    var body: some View {
        Group {
            if ble.state != .ready {
                ContentUnavailableView("Not connected", systemImage: "rectangle.on.rectangle.slash",
                    description: Text("Connect to a Flipper from Home."))
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        screen
                        controls
                    }
                    .padding(Theme.pagePadding)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollIndicators(.hidden)
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle("Remote")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(ScreenView.builtInApps, id: \.0) { item in
                        Button { Task { try? await control.startApp(item.0) } } label: {
                            Label(item.0, systemImage: item.1)
                        }
                    }
                } label: { Image(systemName: "square.grid.2x2") }
                .disabled(ble.state != .ready)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { captureScreenshot() } label: { Image(systemName: "camera") }
                    .disabled(ble.state != .ready)
            }
        }
        .sheet(item: $shareItem) { ActivityView(items: [$0.url]) }
        .onAppear { control.startScreenStream(for: .remote) }
        .onDisappear { control.stopScreenStream(for: .remote) }
    }

    /// Render the current mirror buffer to a PNG (orange bg, black pixels, 8×) and
    /// hand it to the share sheet.
    private func captureScreenshot() {
        let w = FlipperControl.screenW, h = FlipperControl.screenH
        let px = control.screenPixels
        guard px.count >= w * h else { return }
        let scale = 8
        let size = CGSize(width: w * scale, height: h * scale)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.96, green: 0.55, blue: 0.06, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            for y in 0..<h {
                for x in 0..<w where px[y * w + x] {
                    ctx.cgContext.fill(CGRect(x: x * scale, y: y * scale, width: scale, height: scale))
                }
            }
        }
        guard let data = img.pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flipper-screen.png")
        try? data.write(to: url)
        shareItem = ShareImage(url: url)
    }

    private var screen: some View {
        FlipperScreenCanvas(pixels: control.screenPixels)
            .frame(maxWidth: 520)
            .padding(.horizontal, 4)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Flipper controls", systemImage: "gamecontroller.fill")
                    .font(.headline)
                Spacer()
                Text("D-pad")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                dpadButton(.up, "chevron.up", "Up")
                HStack(spacing: 8) {
                    dpadButton(.left, "chevron.left", "Left")
                    dpadButton(.ok, "circle.fill", "OK", tint: Theme.accent)
                    dpadButton(.right, "chevron.right", "Right")
                }
                dpadButton(.down, "chevron.down", "Down")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                Circle()
                    .fill(Color(.tertiarySystemFill))
                    .overlay { Circle().strokeBorder(Theme.accent.opacity(0.12), lineWidth: 1) }
            }

            Button {
                control.press(.back)
            } label: {
                Label("Back", systemImage: "arrow.uturn.left")
            }
            .buttonStyle(FlipperBackButtonStyle())
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .card(tint: Theme.accent, padding: 14)
    }

    private func dpadButton(_ key: PBGui_InputKey,
                            _ icon: String,
                            _ label: String,
                            tint: Color = .primary) -> some View {
        Button {
            control.press(key)
        } label: {
            Image(systemName: icon)
                .accessibilityLabel(label)
        }
        .buttonStyle(FlipperRemoteButtonStyle(tint: tint))
        .accessibilityHint("Sends a \(label.lowercased()) input to Flipper")
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
            control.press(key, type: .long)
        })
    }
}
