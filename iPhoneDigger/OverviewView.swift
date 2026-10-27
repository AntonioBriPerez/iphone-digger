import SwiftUI

struct OverviewView: View {
    @Environment(Agent.self) private var agent
    private let columns = [GridItem(.adaptive(minimum: 210), spacing: 12)]

    var body: some View {
        ScrollView {
            if let info = agent.info {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(systemName: "iphone").font(.system(size: 44)).foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(agent.deviceName).font(.largeTitle.bold())
                            Text("\(info.model) · iOS \(info.ios)").foregroundStyle(.secondary)
                        }
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        batteryCards
                        let used = info.storageTotal - info.storageFree
                        StatCard(title: "Almacenamiento", value: bytes(used),
                                 subtitle: "de \(bytes(info.storageTotal)) · libres \(bytes(info.storageFree))",
                                 icon: "internaldrive", tint: .purple,
                                 progress: info.storageTotal > 0 ? used / info.storageTotal : nil)
                        if let s = agent.system {
                            StatCard(title: "CPU", value: percent(s.cpu), subtitle: "\(s.perCpu.count) núcleos · \(s.threads ?? 0) hilos",
                                     icon: "cpu", tint: .blue, progress: (s.cpu ?? 0) / 100)
                            StatCard(title: "Memoria", value: bytes(s.memUsed, .memory), subtitle: "de \(bytes(s.memTotal, .memory))",
                                     icon: "memorychip", tint: .teal, progress: s.memTotal > 0 ? s.memUsed / s.memTotal : nil)
                        }
                        StatCard(title: "Modo desarrollador", value: info.developerMode == true ? "Activado" : "Desactivado",
                                 subtitle: agent.devStatus == "ok" ? "CPU, procesos y pantalla disponibles" : "Solo datos básicos",
                                 icon: "hammer", tint: .orange)
                    }
                    GroupBox("Dispositivo") {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            ForEach(info.fields, id: \.self) { f in
                                GridRow {
                                    Text(f[0]).foregroundStyle(.secondary)
                                    Text(agent.masked(f[1], label: f[0])).textSelection(.enabled).monospaced()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder private var batteryCards: some View {
        if let b = agent.battery {
            let state = b.charging == true ? "Cargando" : (b.external == true ? "Conectado" : "Con batería")
            StatCard(title: "Batería", value: "\(b.level ?? 0)%",
                     subtitle: "\(state) · \(b.remainingMah ?? 0) mAh · \(String(format: "%.2f V", Double(b.voltageMv ?? 0) / 1000))",
                     icon: b.charging == true ? "battery.100.bolt" : "battery.75", tint: .green,
                     progress: Double(b.level ?? 0) / 100)
            StatCard(title: "Salud de la batería", value: percent(b.health),
                     subtitle: "\(b.maxMah ?? 0) / \(b.designMah ?? 0) mAh · \(b.cycles ?? 0) ciclos",
                     icon: "heart.text.square", tint: (b.health ?? 100) < 80 ? .red : .green, progress: (b.health ?? 0) / 100)
            StatCard(title: "Consumo ahora", value: b.systemLoadMw.map { String(format: "%.2f W", Double($0) / 1000) } ?? "—",
                     subtitle: [b.amperageMa.map { "\($0) mA" }, b.tempC.map { String(format: "%.1f ºC", $0) },
                                b.charging == true ? b.powerInMw.map { String(format: "entrada %.1f W", Double($0) / 1000) } : nil]
                         .compactMap { $0 }.joined(separator: " · "),
                     icon: "bolt", tint: .yellow)
        }
    }
}
