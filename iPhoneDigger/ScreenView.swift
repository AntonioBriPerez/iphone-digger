import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ScreenView: View {
    @Environment(Agent.self) private var agent
    @State private var recorder: ScreenRecorder?

    var body: some View {
        @Bindable var agent = agent
        VStack {
            DeveloperBanner()
            if let image = agent.screenshot {
                Image(nsImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(radius: 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Sin captura", systemImage: "camera", description: Text("Pulsa «Capturar» o activa «En vivo»."))
            }
        }
        .padding(20)
        .toolbar {
            Toggle(isOn: $agent.liveScreen) { Label("En vivo", systemImage: "dot.radiowaves.left.and.right") }
            Button { agent.send(["cmd": "screenshot"]) } label: { Label("Capturar", systemImage: "camera") }
            Button(action: save) { Label("Guardar…", systemImage: "square.and.arrow.down") }.disabled(agent.screenshot == nil)
            if let recorder {
                Button(action: stopRecording) { Label("Detener grabación (\(recorder.frames) fotogramas)", systemImage: "stop.circle.fill") }
                    .labelStyle(.titleAndIcon)
                    .tint(.red)
            } else {
                Button(action: startRecording) { Label("Grabar vídeo…", systemImage: "record.circle") }
                    .help("Graba la pantalla en un vídeo .mp4 (1-2 fotogramas por segundo: es lo que da el servicio de capturas)")
            }
        }
        .onChange(of: agent.screenshot) { _, image in if let image { recorder?.append(image) } }
        .task(id: agent.devStatus) { if agent.devStatus == "ok" && agent.screenshot == nil { agent.send(["cmd": "screenshot"]) } }
        .onDisappear {
            stopRecording()
            agent.liveScreen = false
        }
    }

    private func startRecording() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "iphone-\(Int(Date().timeIntervalSince1970)).mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recorder = ScreenRecorder(url: url)
        agent.liveScreen = true
    }

    private func stopRecording() {
        guard let r = recorder else { return }
        recorder = nil
        Task {
            if await r.finish() { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }
        }
    }

    private func save() {
        guard let tiff = agent.screenshot?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "iphone-\(Int(Date().timeIntervalSince1970)).png"
        if panel.runModal() == .OK, let url = panel.url { try? png.write(to: url) }
    }
}

/// Writes live screenshots to an HEVC .mp4, timed by when each frame arrived.
@MainActor @Observable
final class ScreenRecorder {
    let url: URL
    private(set) var frames = 0
    @ObservationIgnored private var writer: AVAssetWriter?
    @ObservationIgnored private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    @ObservationIgnored private var start = Date()
    @ObservationIgnored private var size = CGSize.zero

    init(url: URL) {
        self.url = url
        try? FileManager.default.removeItem(at: url)  // the save panel already confirmed replacing it
    }

    func append(_ image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        if writer == nil { setUp(width: cg.width, height: cg.height) }
        guard let adaptor, adaptor.assetWriterInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.setFillColor(.black)
        ctx?.fill(CGRect(origin: .zero, size: size))
        // A rotated phone sends landscape frames: fit them inside the size fixed by the first frame.
        let scale = min(size.width / CGFloat(cg.width), size.height / CGFloat(cg.height))
        let w = CGFloat(cg.width) * scale, h = CGFloat(cg.height) * scale
        ctx?.draw(cg, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if adaptor.append(buffer, withPresentationTime: CMTime(seconds: Date().timeIntervalSince(start), preferredTimescale: 600)) { frames += 1 }
    }

    private func setUp(width: Int, height: Int) {
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = true
        w.add(input)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        w.startWriting()
        w.startSession(atSourceTime: .zero)
        writer = w
        size = CGSize(width: width, height: height)
        start = .now
    }

    func finish() async -> Bool {
        guard let writer, frames > 0 else { return false }
        adaptor?.assetWriterInput.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }
}
