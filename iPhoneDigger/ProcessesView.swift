import SwiftUI

struct ProcessesView: View {
    @Environment(Agent.self) private var agent
    @State private var sort = [KeyPathComparator(\Proc.cpu, order: .reverse)]
    @State private var search = ""

    var body: some View {
        let rows = agent.procs
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || "\($0.pid)" == search }
            .sorted(using: sort)
        VStack(spacing: 0) {
            DeveloperBanner().padding([.horizontal, .top], 12)
            Table(rows, sortOrder: $sort) {
                TableColumn("Proceso", value: \.name)
                TableColumn("PID", value: \.pid) { Text(verbatim: String($0.pid)).monospacedDigit() }.width(60)
                TableColumn("CPU %", value: \.cpu) { Text(String(format: "%.1f", $0.cpu)).monospacedDigit() }.width(70)
                TableColumn("Memoria", value: \.mem) { Text(bytes($0.mem, .memory)).monospacedDigit() }.width(90)
                TableColumn("Energía", value: \.power) { Text(String(format: "%.0f", $0.power)).monospacedDigit() }.width(70)
                TableColumn("Escrito en disco", value: \.diskW) { Text(bytes($0.diskW)).monospacedDigit() }.width(110)
                TableColumn("Hilos") { Text(verbatim: String($0.threads ?? 0)).monospacedDigit() }.width(50)
            }
        }
        .searchable(text: $search, prompt: "Filtrar procesos")
        .navigationSubtitle("\(agent.procs.count) procesos")
    }
}
