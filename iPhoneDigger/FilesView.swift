import SwiftUI

/// Browse the Documents folder of apps that enable File Sharing, and copy files in and out.
struct FilesView: View {
    @Environment(Agent.self) private var agent
    @State private var bundle: String?
    @State private var selection = Set<RemoteFile.ID>()
    @State private var confirmDelete = false
    static let root = "/Documents"

    var body: some View {
        let apps = (agent.apps ?? []).filter { $0.sharing == true }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        HSplitView {
            List(apps, selection: $bundle) { a in
                Text(a.name).tag(a.bundle)
            }
            .overlay { if agent.apps == nil { ProgressView("Leyendo apps…") } }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)
            Group {
                if let f = agent.files, f.bundle == bundle {
                    browser(f.dir, f.items)
                } else if bundle != nil {
                    ProgressView()
                } else {
                    ContentUnavailableView("Elige una app", systemImage: "folder",
                                           description: Text("Solo aparecen las apps que permiten compartir archivos con el ordenador."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSubtitle(agent.filesBusy ? "Trabajando…" : agent.fileMessage ?? "")
        .toolbar {
            Button(action: upload) { Label("Subir…", systemImage: "square.and.arrow.up") }.disabled(currentDir == nil)
            Button(action: download) { Label("Descargar…", systemImage: "square.and.arrow.down") }.disabled(selection.isEmpty)
            Button { confirmDelete = true } label: { Label("Eliminar", systemImage: "trash") }.disabled(selection.isEmpty)
        }
        .confirmationDialog("¿Eliminar \(selection.count) elemento(s) del iPhone?", isPresented: $confirmDelete) {
            Button("Eliminar", role: .destructive) { remove() }
        } message: {
            Text("No se puede deshacer.")
        }
        .onChange(of: bundle) { _, b in
            selection = []
            if let b { agent.fileOp(b, "ls", path: Self.root) }
        }
        .task { if agent.apps == nil { agent.send(["cmd": "apps"]) } }
    }

    private var currentDir: String? { agent.files.flatMap { $0.bundle == bundle ? $0.dir : nil } }

    private func browser(_ dir: String, _ items: [RemoteFile]) -> some View {
        let rows = items.sorted { ($0.dir ? 0 : 1, $0.name.lowercased()) < ($1.dir ? 0 : 1, $1.name.lowercased()) }
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { open((dir as NSString).deletingLastPathComponent) } label: { Image(systemName: "chevron.up") }
                    .disabled(dir == Self.root)
                    .help("Carpeta superior")
                Text(dir.split(separator: "/").joined(separator: " › ")).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer()
                if agent.filesBusy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            Table(rows, selection: $selection) {
                TableColumn("Nombre") { Label($0.name, systemImage: $0.dir ? "folder.fill" : "doc") }
                TableColumn("Tamaño") { Text($0.dir ? "—" : bytes($0.size)).monospacedDigit() }.width(90)
                TableColumn("Modificado") { Text(Date(timeIntervalSince1970: $0.mtime), format: .dateTime.day().month().year().hour().minute()) }.width(150)
            }
            .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
                Button("Descargar…") { selection = ids; download() }
                Button("Eliminar…", role: .destructive) { selection = ids; confirmDelete = true }
            } primaryAction: { ids in
                if ids.count == 1, let name = ids.first, rows.first(where: { $0.name == name })?.dir == true { open("\(dir)/\(name)") }
            }
            .dropDestination(for: URL.self) { urls, _ in
                push(urls)
                return true
            }
            .overlay {
                if rows.isEmpty { ContentUnavailableView("Carpeta vacía", systemImage: "tray", description: Text("Arrastra archivos aquí para subirlos al iPhone.")) }
            }
        }
    }

    private func open(_ path: String) {
        guard let bundle else { return }
        selection = []
        agent.fileOp(bundle, "ls", path: path)
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { push(panel.urls) }
    }

    private func push(_ urls: [URL]) {
        guard let bundle, let dir = currentDir else { return }
        for url in urls where url.isFileURL { agent.fileOp(bundle, "push", path: dir, local: url.path) }
    }

    private func download() {
        guard let bundle, let dir = currentDir else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Descargar aquí"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        for name in selection { agent.fileOp(bundle, "pull", path: "\(dir)/\(name)", local: dest.path) }
    }

    private func remove() {
        guard let bundle, let dir = currentDir else { return }
        for name in selection { agent.fileOp(bundle, "rm", path: "\(dir)/\(name)") }
        selection = []
    }
}
