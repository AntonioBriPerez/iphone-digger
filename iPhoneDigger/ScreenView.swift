import SwiftUI
import UniformTypeIdentifiers

struct ScreenView: View {
    @Environment(Agent.self) private var agent

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
        }
        .task(id: agent.devStatus) { if agent.devStatus == "ok" && agent.screenshot == nil { agent.send(["cmd": "screenshot"]) } }
        .onDisappear { agent.liveScreen = false }
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
