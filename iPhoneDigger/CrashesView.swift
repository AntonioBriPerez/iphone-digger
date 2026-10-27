import SwiftUI

struct CrashReport: Identifiable, Hashable {
    let path: String
    var id: String { path }
    var file: String { (path as NSString).lastPathComponent }

    /// "WhatsApp-2026-10-05-083444.ips" -> ("WhatsApp", "2026-10-05 08:34:44")
    var process: String {
        file.range(of: #"-\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression).map { String(file[..<$0.lowerBound]) }
            ?? (file as NSString).deletingPathExtension
    }
    var date: String {
        guard let r = file.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return "" }
        let s = file[r]
        return "\(s.prefix(10)) \(s.dropFirst(11).prefix(2)):\(s.dropFirst(13).prefix(2)):\(s.dropFirst(15).prefix(2))"
    }
}

struct CrashesView: View {
    @Environment(Agent.self) private var agent
    @State private var selection: CrashReport?
    @State private var search = ""

    var body: some View {
        let reports = (agent.crashes ?? []).map(CrashReport.init).sorted { $0.date > $1.date }
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
                        VStack(alignment: .leading) {
                            Text(r.process)
                            Text(r.date.isEmpty ? r.file : r.date).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(r)
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 300)
            Group {
                if let c = agent.crash, c.path == selection?.path {
                    ScrollView { Text(c.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding() }
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
            Button { agent.crashes = nil; agent.send(["cmd": "crashes"]) } label: { Label("Actualizar", systemImage: "arrow.clockwise") }
        }
        .onChange(of: selection) { _, r in if let r { agent.send(["cmd": "crash", "path": r.path]) } }
        .task { if agent.crashes == nil { agent.send(["cmd": "crashes"]) } }
    }
}
