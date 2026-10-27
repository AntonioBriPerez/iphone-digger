import SwiftUI

struct AppsView: View {
    @Environment(Agent.self) private var agent
    @State private var sort = [KeyPathComparator(\AppItem.total, order: .reverse)]
    @State private var search = ""

    var body: some View {
        Group {
            if let apps = agent.apps {
                let rows = apps
                    .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundle.localizedCaseInsensitiveContains(search) }
                    .sorted(using: sort)
                Table(rows, sortOrder: $sort) {
                    TableColumn("App", value: \.name) { a in
                        VStack(alignment: .leading) {
                            Text(a.name)
                            Text(a.bundle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("Versión") { Text($0.version ?? "—") }.width(80)
                    TableColumn("Total", value: \.total) { Text(bytes($0.total)).monospacedDigit() }.width(80)
                    TableColumn("Datos", value: \.dynamicSize) { Text(bytes($0.dynamicSize)).monospacedDigit() }.width(80)
                    TableColumn("Permisos que declara") { Text($0.permissions.joined(separator: ", ")).help($0.permissions.joined(separator: "\n")) }
                    TableColumn("Segundo plano") { Text($0.background.joined(separator: ", ")).foregroundStyle(.secondary) }
                }
                .navigationSubtitle("\(apps.count) apps · \(bytes(apps.reduce(0) { $0 + $1.total }))")
            } else {
                ProgressView("Calculando tamaños de las apps…")
            }
        }
        .searchable(text: $search, prompt: "Buscar app")
        .toolbar {
            Button { agent.apps = nil; agent.send(["cmd": "apps"]) } label: { Label("Actualizar", systemImage: "arrow.clockwise") }
        }
        .task { if agent.apps == nil { agent.send(["cmd": "apps"]) } }
    }
}
