import SwiftUI

struct CrashReport: Identifiable, Hashable {
    let path: String
    var id: String { path }
    var file: String { (path as NSString).lastPathComponent }

    /// "WhatsApp-2026-10-05-083444.ips" -> ("WhatsApp", "2026-10-05 08:34:44")
    var process: String {
        var name = file.range(of: #"-\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression).map { String(file[..<$0.lowerBound]) }
            ?? (file as NSString).deletingPathExtension
        for prefix in ["ExcUserFault_", "stacks+"] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        if ["stacks", "JetsamEvent", "SystemMemoryReset"].contains(name) { return "iOS" }  // system-wide events, not one process
        if let r = name.range(of: #"\.[a-z_]+_resource(_fatal)?$"#, options: .regularExpression) { name.removeSubrange(r) }
        return name
    }
    var date: String {
        guard let r = file.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return "" }
        let s = file[r]
        return "\(s.prefix(10)) \(s.dropFirst(11).prefix(2)):\(s.dropFirst(13).prefix(2)):\(s.dropFirst(15).prefix(2))"
    }

    /// What kind of report it is, from the name iOS gives the file.
    var kind: CrashKind {
        if file.hasPrefix("JetsamEvent") || file.hasPrefix("SystemMemoryReset") { return .memory }
        if file.contains("cpu_resource_fatal") { return .cpuFatal }
        if file.contains("cpu_resource") { return .cpu }
        if file.contains("diskwrites_resource") { return .disk }
        if file.hasPrefix("stacks") { return .hang }
        if file.hasPrefix("ExcUserFault") { return .fault }
        if !file.hasSuffix(".ips") || ["Analytics", "SiriSearchFeedback", "log-", "xp_amp", "Retired"].contains(where: file.hasPrefix) { return .diagnostic }
        return .crash
    }
}

enum CrashKind {
    case crash, memory, cpu, cpuFatal, disk, hang, fault, diagnostic

    var title: String {
        switch self {
        case .crash: "Cierre inesperado"
        case .memory: "Falta de memoria"
        case .cpu: "Uso excesivo de CPU"
        case .cpuFatal: "Cerrada por usar demasiada CPU"
        case .disk: "Escritura excesiva en disco"
        case .hang: "Bloqueo del sistema"
        case .fault: "Fallo no fatal"
        case .diagnostic: "Diagnóstico"
        }
    }

    var icon: String {
        switch self {
        case .crash, .cpuFatal: "xmark.octagon"
        case .memory: "memorychip"
        case .cpu: "cpu"
        case .disk: "internaldrive"
        case .hang: "hourglass"
        case .fault: "exclamationmark.circle"
        case .diagnostic: "doc.text"
        }
    }

    var tint: Color {
        switch self {
        case .crash, .cpuFatal: .red
        case .memory, .hang: .orange
        case .cpu, .disk, .fault: .yellow
        case .diagnostic: .secondary
        }
    }

    /// Only things the user would notice (an app closing, the phone freezing) deserve a notification.
    var worthNotifying: Bool { [.crash, .memory, .cpuFatal, .hang].contains(self) }

    var explanation: String {
        switch self {
        case .crash: "La app se cerró sola. Abajo tienes el motivo concreto."
        case .memory: "iOS se quedó sin memoria y cerró apps en segundo plano para liberarla (jetsam). Es normal de vez en cuando; si pasa mucho, alguna app está usando demasiada memoria."
        case .cpu: "El proceso usó mucha CPU durante bastante tiempo. iOS lo registró pero no lo cerró; suele notarse en batería y temperatura."
        case .cpuFatal: "iOS cerró el proceso porque usó demasiada CPU en segundo plano."
        case .disk: "El proceso escribió muchísimo en el almacenamiento en poco tiempo. No es un cierre, pero desgasta la memoria y gasta batería."
        case .hang: "El sistema dejó de responder un rato y guardó lo que hacía cada proceso en ese momento."
        case .fault: "El sistema detectó un comportamiento incorrecto, pero la app siguió funcionando."
        case .diagnostic: "Informe de diagnóstico o estadísticas de uso; no indica ningún fallo."
        }
    }
}

/// Plain-language reason for a crash, from the exception and termination codes in the report.
func crashReason(_ text: String) -> String? {
    let rules: [(needles: [String], reason: String)] = [
        // termination codes appear in decimal in the JSON body: 0xc51bad01/02, 0xdead10cc, 0x8badf00d
        (["3306925313", "3306925314", "watchdog transgression"], "watchOS la cerró porque tardó demasiado en una tarea en segundo plano (normalmente, sincronizando con el iPhone). Es un fallo de la app del reloj."),
        (["3735883980", "0xdead10cc"], "iOS la cerró porque se quedó en segundo plano con un archivo o una base de datos compartida bloqueados. Es un error de la app."),
        (["0x8badf00d", "2343432205"], "El sistema la cerró porque tardó demasiado en responder (watchdog). Se quedó colgada, normalmente al arrancar o al volver al primer plano."),
        (["\"bug_type\":\"298\"", "JetsamEvent"], "iOS se quedó sin memoria y cerró procesos para liberarla."),
        (["EXC_RESOURCE"], "Superó un límite de recursos (CPU, memoria o disco) y el sistema la detuvo."),
        (["EXC_GUARD"], "Usó mal un recurso protegido del sistema (un archivo o un canal de comunicación). Es un error de la app."),
        (["EXC_BAD_ACCESS", "SIGSEGV", "SIGBUS"], "Intentó leer o escribir memoria que no le correspondía. Es un error de programación de la app."),
        (["EXC_BREAKPOINT", "SIGTRAP"], "Falló una comprobación interna (en Swift: un valor nulo forzado, un índice fuera de rango…). Es un error de la app."),
        (["SIGABRT", "abort() called"], "La app se detuvo a sí misma, normalmente por un error no controlado."),
        (["SIGKILL"], "El sistema la cerró a la fuerza."),
    ]
    return rules.first { $0.needles.contains(where: text.contains) }?.reason
}

struct CrashesView: View {
    @Environment(Agent.self) private var agent
    @State private var selection: CrashReport?
    @State private var search = ""
    @State private var showDiagnostics = false

    var body: some View {
        let reports = (agent.crashes ?? []).map(CrashReport.init).filter { showDiagnostics || $0.kind != .diagnostic }.sorted { $0.date > $1.date }
        let shown = reports.filter { search.isEmpty || $0.file.localizedCaseInsensitiveContains(search) }
        let top = Dictionary(grouping: reports, by: \.process).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(6)
        HSplitView {
            List(selection: $selection) {
                if !top.isEmpty {
                    Section("Procesos que más fallan") {
                        ForEach(top, id: \.0) { name, count in
                            HStack { Text(name); Spacer(); Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
                                .onTapGesture { search = name }
                        }
                    }
                }
                Section("\(shown.count) informes") {
                    ForEach(shown) { r in
                        Label {
                            VStack(alignment: .leading) {
                                Text(r.process)
                                Text("\(r.kind.title) · \(r.date.isEmpty ? r.file : r.date)").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: r.kind.icon).foregroundStyle(r.kind.tint)
                        }
                        .tag(r)
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 300)
            Group {
                if let c = agent.crash, let r = selection, c.path == r.path {
                    VStack(spacing: 0) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.kind.title).font(.headline)
                                Text(r.kind == .crash ? crashReason(c.text) ?? r.kind.explanation : r.kind.explanation)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } icon: {
                            Image(systemName: r.kind.icon).font(.title2).foregroundStyle(r.kind.tint)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary)
                        Divider()
                        ScrollView { Text(c.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding() }
                    }
                } else if selection != nil {
                    ProgressView()
                } else {
                    ContentUnavailableView("Elige un informe", systemImage: "doc.text.magnifyingglass")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $search, prompt: "Buscar por proceso")
        .overlay { if agent.crashes == nil { ProgressView("Leyendo informes de fallos…") } }
        .toolbar {
            Toggle(isOn: $showDiagnostics) { Label("Diagnósticos", systemImage: "doc.text") }
                .help("Muestra también los informes de estadísticas y diagnóstico, que no son fallos")
            Button { agent.crashes = nil; agent.send(["cmd": "crashes"]) } label: { Label("Actualizar", systemImage: "arrow.clockwise") }
        }
        .navigationSubtitle("Te avisamos con una notificación cuando aparece un fallo nuevo")
        .onChange(of: selection) { _, r in if let r { agent.send(["cmd": "crash", "path": r.path]) } }
        .task { if agent.crashes == nil { agent.send(["cmd": "crashes"]) } }
    }
}
