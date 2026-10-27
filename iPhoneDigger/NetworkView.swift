import SwiftUI
import UniformTypeIdentifiers

struct NetworkView: View {
    @Environment(Agent.self) private var agent
    @State private var sort = [KeyPathComparator(\NetFlow.total, order: .reverse)]
    @State private var search = ""
    @State private var app: String?
    @State private var showApps = true

    var body: some View {
        let flows = agent.net
            .filter { (app == nil || $0.app == app) && (search.isEmpty || [$0.app, $0.destination, $0.ip].contains { $0.localizedCaseInsensitiveContains(search) }) }
            .sorted(using: sort + [KeyPathComparator(\NetFlow.id)])  // fixed tie order: rows only move when their value does
        Group {
            if agent.net.isEmpty {
                ContentUnavailableView("Escuchando el tráfico…", systemImage: "network",
                                       description: Text("Usa el iPhone y aquí irán apareciendo las apps y los servidores con los que hablan."))
            } else {
                Table(flows, sortOrder: $sort) {
                    TableColumn("App", value: \.app) { f in
                        Text(f.app).bold().foregroundStyle(processColor(f.app)).lineLimit(1)
                    }
                    .width(min: 90, ideal: 150)
                    TableColumn("Destino", value: \.destination) { f in
                        VStack(alignment: .leading) {
                            Text(f.destination).lineLimit(1).textSelection(.enabled)
                            if !f.host.isEmpty { Text(f.ip).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        .help(f.host.isEmpty ? "Sin nombre: la IP no tiene DNS inverso y la app no la resolvió por DNS normal" : f.ip)
                    }
                    .width(min: 160, ideal: 300)
                    TableColumn("Puertos") { Text($0.ports.map(portName).joined(separator: ", ")).foregroundStyle(.secondary) }
                        .width(min: 60, ideal: 110)
                    TableColumn("Recibido", value: \.rx) { Text(bytes($0.rx)).monospacedDigit() }.width(80)
                    TableColumn("Enviado", value: \.tx) { Text(bytes($0.tx)).monospacedDigit() }.width(80)
                    TableColumn("Última vez", value: \.last) { Text(Date(timeIntervalSince1970: $0.last), format: .dateTime.hour().minute().second()).monospacedDigit() }
                        .width(80)
                }
                .id(sort)  // re-sorting reloads instead of diffing hundreds of row moves
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Buscar app, dominio o IP")
        .navigationSubtitle(subtitle(flows))
        .inspector(isPresented: $showApps) {
            NetworkApps(flows: agent.net, selected: $app).inspectorColumnWidth(min: 220, ideal: 260, max: 360)
        }
        .safeAreaInset(edge: .bottom) {
            Text("Bytes medidos en el cable, desde que abriste esta página. Con una VPN activa el tráfico sale dos veces: dentro del túnel por app y cifrado hacia el servidor VPN.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
        .toolbar {
            if agent.pcap?.on == true {
                Button { agent.send(["cmd": "pcap", "path": ""]) } label: {
                    Label("Detener captura (\(agent.pcap?.packets ?? 0) paquetes)", systemImage: "stop.circle.fill")
                }
                .labelStyle(.titleAndIcon)
                .tint(.red)
            } else {
                Button(action: startCapture) { Label("Capturar .pcap…", systemImage: "record.circle") }
                    .help("Guarda todo el tráfico en un archivo que se abre con Wireshark")
            }
            Button { showApps.toggle() } label: { Label("Apps", systemImage: "sidebar.right") }
        }
        .task { agent.send(["cmd": "net"]) }
    }

    private func subtitle(_ flows: [NetFlow]) -> String {
        let apps = Set(agent.net.map(\.app)).count
        return "\(apps) apps · \(flows.count) destinos · ↓ \(bytes(flows.reduce(0) { $0 + $1.rx })) · ↑ \(bytes(flows.reduce(0) { $0 + $1.tx }))"
    }

    private func startCapture() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pcapng") ?? .data]
        panel.nameFieldStringValue = "iphone-\(Int(Date().timeIntervalSince1970)).pcapng"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        agent.send(["cmd": "pcap", "path": url.path])
    }
}

func portName(_ port: Int) -> String {
    let known = [443: "HTTPS", 80: "HTTP", 53: "DNS", 853: "DNS cifrado", 5223: "Notificaciones push", 3478: "STUN", 993: "IMAP", 587: "SMTP", 123: "Hora"]
    return known[port] ?? (port == 0 ? "—" : String(port))
}

/// Apps ranked by traffic; click one to see only its destinations.
struct NetworkApps: View {
    let flows: [NetFlow]
    @Binding var selected: String?

    var body: some View {
        let apps = Dictionary(grouping: flows, by: \.app)
            .map { (name: $0.key, total: $0.value.reduce(0) { $0 + $1.total }, destinations: $0.value.count) }
            .sorted { $0.total > $1.total }
        List {
            if selected != nil {
                Section {
                    Button { selected = nil } label: { Label("Mostrar todas las apps", systemImage: "xmark.circle") }
                }
            }
            Section("Más tráfico · pulsa para ver solo una") {
                ForEach(apps, id: \.name) { a in
                    HStack(spacing: 6) {
                        Circle().fill(processColor(a.name)).frame(width: 8, height: 8)
                        VStack(alignment: .leading) {
                            Text(a.name).lineLimit(1).fontWeight(selected == a.name ? .bold : .regular)
                            Text("\(a.destinations) destinos").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(bytes(a.total)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selected = selected == a.name ? nil : a.name }
                }
            }
        }
        .font(.callout)
    }
}
