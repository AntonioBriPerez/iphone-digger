import SwiftUI
import UniformTypeIdentifiers

struct LogsView: View {
    @Environment(Agent.self) private var agent
    @State private var search = ""
    @State private var frozen: [LogLine]?  // nil = live; otherwise the snapshot taken when pausing
    @State private var selected: LogLine.ID?
    @State private var showProcesses = true

    var body: some View {
        @Bindable var agent = agent
        let source = frozen ?? agent.logs
        let shown = source.filter { agent.logPasses($0) && matches($0) }
        let pending = frozen.map { f in agent.logs.reversed().prefix { $0.id > (f.last?.id ?? 0) }.count } ?? 0

        VStack(spacing: 0) {
            if shown.isEmpty {
                ContentUnavailableView(source.isEmpty ? "Esperando logs…" : "Ninguna línea coincide",
                                       systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text(source.isEmpty ? "" : "Prueba a bajar el nivel, quitar la búsqueda o reactivar procesos silenciados."))
            } else {
                list(shown)
            }
            if frozen != nil { pausedBar(pending) }
            if let id = selected, let line = source.first(where: { $0.id == id }) {
                Divider()
                LogDetail(line: line, close: { selected = nil })
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Buscar en proceso, subsistema o mensaje")
        .navigationSubtitle(subtitle(shown: shown.count, total: source.count))
        .inspector(isPresented: $showProcesses) {
            LogProcesses(lines: agent.logs).inspectorColumnWidth(min: 220, ideal: 260, max: 360)
        }
        .toolbar {
            Toggle(isOn: Binding(get: { frozen == nil }, set: { live in frozen = live ? nil : agent.logs; if live { selected = nil } })) {
                Label(frozen == nil ? "En vivo" : "Pausado", systemImage: frozen == nil ? "dot.radiowaves.left.and.right" : "pause.fill")
            }
            .help("En vivo: las líneas nuevas aparecen al momento. Pausado: congela la vista para leer; las nuevas se siguen recogiendo.")
            Picker("Nivel", selection: $agent.logMinLevel) {
                Text("Todo").tag(0)
                Text("Sin depuración").tag(1)
                Text("Importante").tag(2)
                Text("Errores y fallos").tag(3)
            }
            .help("Nivel mínimo que se muestra")
            Button { export(shown) } label: { Label("Exportar…", systemImage: "square.and.arrow.up") }
                .help("Guarda las líneas visibles en un archivo .log")
            Button { agent.logs = []; frozen = frozen.map { _ in [] }; selected = nil } label: { Label("Limpiar", systemImage: "trash") }
            Button { showProcesses.toggle() } label: { Label("Procesos", systemImage: "sidebar.right") }
                .help("Procesos que más escriben: pulsa para filtrar, silencia los ruidosos")
        }
    }

    private func list(_ shown: [LogLine]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { l in
                        LogRow(line: l, query: search, selected: l.id == selected)
                            .id(l.id)
                            .onTapGesture {
                                selected = selected == l.id ? nil : l.id
                                if frozen == nil { frozen = agent.logs }  // reading a line: stop it scrolling away
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: shown.last?.id) { _, id in
                if let id, frozen == nil { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func pausedBar(_ pending: Int) -> some View {
        HStack {
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            Text(pending > 0 ? "Pausado · \(pending) líneas nuevas esperando" : "Pausado")
            Spacer()
            Button("Volver al directo") { frozen = nil; selected = nil }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.orange.opacity(0.12))
    }

    private func matches(_ l: LogLine) -> Bool {
        search.isEmpty || l.msg.localizedCaseInsensitiveContains(search) || l.proc.localizedCaseInsensitiveContains(search)
            || (l.sub ?? "").localizedCaseInsensitiveContains(search)
    }

    private func subtitle(shown: Int, total: Int) -> String {
        var parts = ["\(shown.formatted()) de \(total.formatted()) líneas", "llegan \(agent.logRate.formatted())/s"]
        if !agent.logOnly.isEmpty { parts.append("solo \(agent.logOnly)") }
        if !agent.logMuted.isEmpty { parts.append("\(agent.logMuted.count) silenciados") }
        if agent.logsDropped > 0 { parts.append("\(agent.logsDropped.formatted()) descartadas por volumen") }
        return parts.joined(separator: " · ")
    }

    private func export(_ lines: [LogLine]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.log]
        panel.nameFieldStringValue = "iphone-logs-\(Int(Date().timeIntervalSince1970)).log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = lines.map { "\($0.ts) \($0.level) \($0.proc)[\($0.pid)] \($0.sub ?? "") \($0.msg)" }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Pieces

/// Stable per-run colour so the same process is easy to follow down the list.
func processColor(_ name: String) -> Color {
    Color(hue: Double(UInt(bitPattern: name.hashValue) % 360) / 360, saturation: 0.55, brightness: 0.8)
}

struct LevelBadge: View {
    let line: LogLine

    var body: some View {
        let (text, color): (String, Color) = switch line.level {
        case "FAULT": ("FALLO", .purple)
        case "ERROR": ("ERROR", .red)
        case "USER_ACTION": ("ACCIÓN", .blue)
        case "INFO": ("info", .secondary)
        case "DEBUG": ("debug", .secondary)
        default: ("", .clear)
        }
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(line.rank >= 3 ? .white : color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(line.rank >= 3 ? color : .clear, in: RoundedRectangle(cornerRadius: 3))
            .frame(width: 52)
    }
}

struct LogRow: View {
    let line: LogLine
    let query: String
    let selected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.ts).foregroundStyle(.tertiary)
            LevelBadge(line: line)
            Text(line.proc).bold().foregroundStyle(processColor(line.proc))
                .frame(width: 150, alignment: .leading).lineLimit(1)
            Text(highlighted).lineLimit(1)
                .foregroundStyle(line.rank < 2 ? .secondary : .primary)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.3) : line.rank >= 3 ? Color.red.opacity(0.07) : .clear)
        .contentShape(Rectangle())
    }

    private var highlighted: AttributedString {
        var s = AttributedString(line.msg)
        guard !query.isEmpty else { return s }
        var rest = s.startIndex..<s.endIndex
        while let r = s[rest].range(of: query, options: .caseInsensitive) {
            s[r].backgroundColor = .yellow.opacity(0.45)
            rest = r.upperBound..<s.endIndex
        }
        return s
    }
}

struct LogDetail: View {
    @Environment(Agent.self) private var agent
    let line: LogLine
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                LevelBadge(line: line)
                Text("\(line.proc) [\(line.pid, format: .number.grouping(.never))]").bold().foregroundStyle(processColor(line.proc))
                if let sub = line.sub, !sub.isEmpty {
                    Text([sub, line.cat ?? ""].filter { !$0.isEmpty }.joined(separator: " › ")).foregroundStyle(.secondary)
                }
                Text(line.ts).foregroundStyle(.tertiary)
                Spacer()
                Button("Solo este proceso") { agent.logOnly = line.proc }
                Button("Silenciar proceso") { agent.logMuted.insert(line.proc) }
                Button { copy() } label: { Label("Copiar", systemImage: "doc.on.doc") }
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            }
            .font(.callout)
            ScrollView {
                Text(line.msg).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            if line.msg.contains("<private>") {
                Text("«<private>» es un dato que iOS oculta en los logs para proteger tu privacidad; no se puede recuperar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.background.secondary)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(line.ts) \(line.level) \(line.proc)[\(line.pid)] \(line.msg)", forType: .string)
    }
}

/// Which processes are writing the most, with one-click focus and mute.
struct LogProcesses: View {
    @Environment(Agent.self) private var agent
    let lines: [LogLine]

    var body: some View {
        let stats = Dictionary(grouping: lines, by: \.proc)
            .map { (name: $0.key, count: $0.value.count, errors: $0.value.count { $0.rank >= 3 }) }
            .sorted { $0.count > $1.count }
        List {
            if !agent.logOnly.isEmpty {
                Section {
                    Button { agent.logOnly = "" } label: { Label("Mostrar todos los procesos", systemImage: "xmark.circle") }
                }
            }
            Section("Más activos · pulsa para ver solo uno") {
                ForEach(stats.prefix(60), id: \.name) { p in
                    HStack(spacing: 6) {
                        Circle().fill(processColor(p.name)).frame(width: 8, height: 8)
                        Text(p.name).lineLimit(1).fontWeight(agent.logOnly == p.name ? .bold : .regular)
                        Spacer()
                        if p.errors > 0 { Text("\(p.errors)").foregroundStyle(.red).help("Errores y fallos") }
                        Text("\(p.count)").foregroundStyle(.secondary).monospacedDigit()
                        Button { agent.logMuted.insert(p.name); if agent.logOnly == p.name { agent.logOnly = "" } } label: {
                            Image(systemName: "speaker.slash")
                        }
                        .buttonStyle(.borderless).help("Silenciar \(p.name)")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { agent.logOnly = agent.logOnly == p.name ? "" : p.name }
                }
            }
            if !agent.logMuted.isEmpty {
                Section("Silenciados") {
                    ForEach(agent.logMuted.sorted(), id: \.self) { name in
                        HStack {
                            Text(name).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button("Reactivar") { agent.logMuted.remove(name) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .font(.callout)
    }
}
