import SwiftUI

struct LogsView: View {
    @Environment(Agent.self) private var agent
    @State private var filter = ""

    var body: some View {
        @Bindable var agent = agent
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(agent.logs) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(l.ts).foregroundStyle(.secondary)
                            Text(l.proc).bold().frame(width: 150, alignment: .leading).lineLimit(1)
                            Text(l.msg).foregroundStyle(color(l.level)).textSelection(.enabled)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .id(l.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: agent.logs.last?.id) { _, id in
                if let id, !agent.logsPaused { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .navigationSubtitle("\(agent.logs.count) líneas · \(agent.logsDropped) descartadas por volumen")
        .toolbar {
            TextField("Filtrar por proceso o texto", text: $filter)
                .frame(width: 240)
                .onSubmit { agent.logFilter = filter }
            Toggle(isOn: $agent.logsPaused) { Label("Pausar", systemImage: "pause") }
            Button { agent.logs = [] } label: { Label("Limpiar", systemImage: "trash") }
        }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "ERROR": .red
        case "FAULT", "USER_ACTION": .pink
        case "DEBUG", "INFO": .secondary
        default: .primary
        }
    }
}
