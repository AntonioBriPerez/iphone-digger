import Charts
import SwiftUI

struct PerformanceView: View {
    @Environment(Agent.self) private var agent

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                DeveloperBanner()
                HStack(spacing: 14) {
                    chart("CPU", unit: "%", points: agent.cpuHistory, color: .blue, domain: 0...100)
                    chart("Memoria usada", unit: "GB", points: agent.memHistory, color: .teal,
                          domain: 0...max(1, (agent.system?.memTotal ?? 0) / 1_073_741_824))
                }
                HStack(spacing: 14) {
                    GroupBox {
                        Chart {
                            ForEach(agent.netInHistory) { LineMark(x: .value("t", $0.date), y: .value("KB/s", $0.value)).foregroundStyle(by: .value("", "Bajada")) }
                            ForEach(agent.netOutHistory) { LineMark(x: .value("t", $0.date), y: .value("KB/s", $0.value)).foregroundStyle(by: .value("", "Subida")) }
                        }
                        .chartXAxis(.hidden)
                        .frame(height: 170)
                    } label: {
                        header("Red (incluye el tráfico USB de la app)", value: (agent.netInHistory.last?.value).map { String(format: "↓ %.0f KB/s  ↑ %.0f KB/s", $0, agent.netOutHistory.last?.value ?? 0) })
                    }
                    chart("Consumo del sistema", unit: "mW", points: agent.powerHistory, color: .yellow, domain: nil)
                }
                if let s = agent.system, !s.perCpu.isEmpty {
                    GroupBox {
                        Chart(Array(s.perCpu.enumerated()), id: \.offset) { i, v in
                            BarMark(x: .value("Núcleo", "\(i)"), y: .value("%", v)).foregroundStyle(.blue.gradient)
                        }
                        .chartYScale(domain: 0...100)
                        .frame(height: 140)
                    } label: {
                        header("Carga por núcleo", value: nil)
                    }
                }
            }
            .padding(20)
        }
        .toolbar {
            if let rows = agent.perfLog {
                Button("Descartar", role: .destructive) { agent.perfLog = nil }
                Button(action: savePerf) { Label("Detener y guardar (\(rows.count) s)", systemImage: "stop.circle.fill") }
                    .labelStyle(.titleAndIcon)
                    .tint(.red)
            } else {
                Button { agent.perfLog = [] } label: { Label("Grabar sesión", systemImage: "record.circle") }
                    .help("Guarda CPU, memoria, red, disco, consumo y el proceso más activo cada segundo, para exportarlo a CSV")
            }
        }
    }

    private func savePerf() {
        guard let rows = agent.perfLog else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "iphone-rendimiento-\(Int(Date().timeIntervalSince1970)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }  // cancelled: keep recording
        do {
            try ([Agent.perfHeader] + rows).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
            agent.perfLog = nil
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            agent.lastError = "No se pudo guardar el CSV: \(error.localizedDescription)"
        }
    }

    private func header(_ title: String, value: String?) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let value { Text(value).monospacedDigit().foregroundStyle(.secondary) }
        }
    }

    private func chart(_ title: String, unit: String, points: [Point], color: Color, domain: ClosedRange<Double>?) -> some View {
        GroupBox {
            let c = Chart(points) {
                AreaMark(x: .value("t", $0.date), y: .value(unit, $0.value)).foregroundStyle(color.opacity(0.2).gradient)
                LineMark(x: .value("t", $0.date), y: .value(unit, $0.value)).foregroundStyle(color)
            }
            .chartXAxis(.hidden)
            .frame(height: 170)
            if let domain { c.chartYScale(domain: domain) } else { c }
        } label: {
            header(title, value: points.last.map { String(format: "%.1f %@", $0.value, unit) })
        }
    }
}
