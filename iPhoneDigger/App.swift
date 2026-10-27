import SwiftUI

@main
struct iPhoneDiggerApp: App {
    @State private var agent = Agent()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(agent)
                .frame(minWidth: 1000, minHeight: 650)
                .onAppear { agent.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    agent.stop()
                }
        }
        .defaultSize(width: 1280, height: 820)
    }
}

enum Page: String, CaseIterable, Identifiable {
    case overview = "Resumen", performance = "Rendimiento", battery = "Batería", processes = "Procesos", network = "Red"
    case screen = "Pantalla", apps = "Apps", files = "Archivos", security = "Seguridad", location = "Ubicación"
    case logs = "Logs en vivo", crashes = "Fallos"
    var id: Self { self }
    var icon: String {
        switch self {
        case .overview: "iphone"
        case .performance: "waveform.path.ecg"
        case .battery: "battery.75"
        case .processes: "cpu"
        case .network: "network"
        case .screen: "rectangle.on.rectangle"
        case .apps: "square.grid.3x3"
        case .files: "folder"
        case .security: "lock.shield"
        case .location: "location"
        case .logs: "text.alignleft"
        case .crashes: "exclamationmark.triangle"
        }
    }
}

struct ContentView: View {
    @Environment(Agent.self) private var agent
    @State private var section: Page? = Page.allCases.first { "\($0)" == UserDefaults.standard.string(forKey: "page") } ?? .overview  // `--args -page logs`

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(210)
            .safeAreaInset(edge: .bottom) { StatusFooter().padding(10) }
        } detail: {
            Group {
                if agent.missingPython {
                    ContentUnavailableView {
                        Label("Falta pymobiledevice3", systemImage: "shippingbox")
                    } description: {
                        Text("Ejecuta ./setup.sh en la carpeta del proyecto y vuelve a abrir la app.")
                    }
                } else if agent.info == nil {
                    ContentUnavailableView {
                        Label("Conecta un iPhone", systemImage: "cable.connector")
                    } description: {
                        Text("Conéctalo por cable, desbloquéalo y pulsa «Confiar» si te lo pide.")
                    }
                } else {
                    switch section ?? .overview {
                    case .overview: OverviewView()
                    case .performance: PerformanceView()
                    case .battery: BatteryView()
                    case .processes: ProcessesView()
                    case .network: NetworkView()
                    case .screen: ScreenView()
                    case .apps: AppsView()
                    case .files: FilesView()
                    case .security: SecurityView()
                    case .location: LocationView()
                    case .logs: LogsView()
                    case .crashes: CrashesView()
                    }
                }
            }
            .navigationTitle(section?.rawValue ?? "")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Toggle(isOn: Bindable(agent).privacy) { Label("Modo privado", systemImage: agent.privacy ? "eye.slash" : "eye") }
                        .help("Oculta número de serie, UDID, IMEI, teléfono y MACs para compartir capturas")
                        .keyboardShortcut("p", modifiers: [.command, .shift])
                }
                if agent.devices.count > 1 {
                    ToolbarItem {
                        Picker("iPhone", selection: Binding(get: { agent.info?.udid ?? "" }, set: { agent.select($0) })) {
                            ForEach(agent.devices, id: \.udid) { d in Text(verbatim: "\(agent.privacy ? "iPhone" : String(d.udid.prefix(8)) + "…") (\(d.conn))").tag(d.udid) }
                        }
                    }
                }
            }
        }
    }
}

struct StatusFooter: View {
    @Environment(Agent.self) private var agent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if agent.info != nil {
                Label(agent.deviceName, systemImage: "iphone").font(.callout.bold()).lineLimit(1)
            }
            HStack(spacing: 6) {
                Circle().fill(agent.devStatus == "ok" ? .green : .orange).frame(width: 7, height: 7)
                Text(agent.devStatus == "ok" ? "Servicios de desarrollador" : "Modo básico").font(.caption)
            }
            if let e = agent.lastError {
                Text(e).font(.caption2).foregroundStyle(.secondary).lineLimit(3).help(e)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
