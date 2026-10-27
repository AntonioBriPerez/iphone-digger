import Charts
import SwiftUI

struct BatteryView: View {
    @Environment(Agent.self) private var agent
    @AppStorage("batteryRange") private var hours = 24.0

    var body: some View {
        let records = agent.batteryLog.filter { $0.date > .now.addingTimeInterval(-hours * 3600) }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Se guarda un punto cada 30 segundos mientras el iPhone está conectado a este Mac (los últimos 30 días). Por cable casi siempre estará cargando; para medir la descarga real, conéctalo por Wi-Fi (Finder › «Mostrar este iPhone cuando esté conectado a una red Wi-Fi»).")
                    .font(.callout).foregroundStyle(.secondary)
                if records.count < 2 {
                    ContentUnavailableView("Aún no hay historial en este periodo", systemImage: "battery.25",
                                           description: Text("Deja la app abierta con el iPhone conectado y vuelve en un rato."))
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) { cards(records) }
                    GroupBox {
                        Chart {
                            ForEach(Array(zip(records, records.dropFirst())), id: \.0.id) { a, b in
                                if a.plugged && b.date.timeIntervalSince(a.date) < 600 {  // one band per stretch on power, no band across gaps
                                    RectangleMark(xStart: .value("Desde", a.date), xEnd: .value("Hasta", b.date), yStart: .value("", 0), yEnd: .value("", 100))
                                        .foregroundStyle(.yellow.opacity(0.12))
                                }
                            }
                            ForEach(records) { r in
                                LineMark(x: .value("Hora", r.date), y: .value("%", r.level)).foregroundStyle(.green)
                            }
                        }
                        .chartYScale(domain: 0...100)
                        .frame(height: 180)
                    } label: {
                        Label("Nivel de batería (fondo amarillo: conectado a corriente)", systemImage: "battery.75").font(.headline)
                    }
                    GroupBox {
                        Chart(records.filter { $0.loadMw != nil }) { r in
                            AreaMark(x: .value("Hora", r.date), y: .value("W", Double(r.loadMw ?? 0) / 1000)).foregroundStyle(.orange.opacity(0.25).gradient)
                            LineMark(x: .value("Hora", r.date), y: .value("W", Double(r.loadMw ?? 0) / 1000)).foregroundStyle(.orange)
                        }
                        .frame(height: 180)
                    } label: {
                        Label("Consumo del sistema (W)", systemImage: "bolt").font(.headline)
                    }
                    GroupBox {
                        let named = records.filter { !$0.topProc.isEmpty && !Agent.isInstrumentation($0.topProc) }
                        let top = Dictionary(grouping: named, by: \.topProc)
                            .map { (name: $0.key, share: Double($0.value.count) / Double(named.count)) }
                            .sorted { $0.share > $1.share }.prefix(10)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(top, id: \.name) { p in
                                HStack {
                                    Circle().fill(processColor(p.name)).frame(width: 8, height: 8)
                                    Text(p.name)
                                    Spacer()
                                    Text(p.share, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(6)
                    } label: {
                        Label("El que más energía gastaba en cada momento (% del tiempo)", systemImage: "flame").font(.headline)
                    }
                }
            }
            .padding(20)
        }
        .toolbar {
            Picker("Periodo", selection: $hours) {
                Text("1 hora").tag(1.0)
                Text("6 horas").tag(6.0)
                Text("24 horas").tag(24.0)
                Text("7 días").tag(168.0)
                Text("30 días").tag(720.0)
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder private func cards(_ records: [BatteryRecord]) -> some View {
        let loads = records.compactMap(\.loadMw)
        let temps = records.compactMap(\.tempC)
        StatCard(title: "Consumo medio", value: loads.isEmpty ? "—" : String(format: "%.2f W", Double(loads.reduce(0, +)) / Double(loads.count) / 1000),
                 subtitle: loads.max().map { String(format: "pico %.2f W", Double($0) / 1000) }, icon: "bolt", tint: .orange)
        if let maxTemp = temps.max() {
            StatCard(title: "Temperatura", value: String(format: "%.1f ºC", maxTemp),
                     subtitle: String(format: "máxima · media %.1f ºC", temps.reduce(0, +) / Double(temps.count)),
                     icon: "thermometer.medium", tint: maxTemp > 40 ? .red : .green)
        } else {  // iOS 27 no longer reports battery temperature over USB
            StatCard(title: "Registro", value: "\(records.count) puntos",
                     subtitle: "desde \(records[0].date.formatted(date: .abbreviated, time: .shortened))", icon: "clock", tint: .blue)
        }
        StatCard(title: "Gasto sin cargador", value: drainPerHour(records).map { String(format: "%.1f %%/h", $0) } ?? "—",
                 subtitle: drainPerHour(records) == nil ? "Necesita ratos sin corriente (conexión Wi-Fi)" : "media de los ratos sin corriente",
                 icon: "battery.50", tint: .green)
    }

    /// Battery % lost per hour, using only consecutive samples taken while unplugged.
    private func drainPerHour(_ records: [BatteryRecord]) -> Double? {
        var lost = 0.0, seconds = 0.0
        for (a, b) in zip(records, records.dropFirst()) where !a.plugged && !b.plugged && b.date.timeIntervalSince(a.date) < 600 {
            lost += Double(a.level - b.level)
            seconds += b.date.timeIntervalSince(a.date)
        }
        return seconds >= 600 ? lost / seconds * 3600 : nil
    }
}
