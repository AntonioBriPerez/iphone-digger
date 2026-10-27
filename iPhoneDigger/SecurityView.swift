import SwiftUI

struct SecurityView: View {
    @Environment(Agent.self) private var agent

    var body: some View {
        Group {
            if let s = agent.security {
                List {
                    Section("Resumen") {
                        Check(ok: s.supervised != true, title: s.supervised == true ? "Supervisado por una organización" : "No está supervisado",
                              detail: s.supervised == true ? "Una empresa o colegio puede gestionar este iPhone a distancia (MDM): instalar apps, ver su inventario y aplicar restricciones."
                                  : "Ninguna organización gestiona este iPhone a distancia.")
                        Check(ok: s.profiles.isEmpty, title: s.profiles.isEmpty ? "Sin perfiles de configuración" : "\(s.profiles.count) perfil(es) instalados",
                              detail: "Un perfil puede instalar certificados raíz (que permiten leer tu tráfico cifrado), VPN, DNS o restricciones. Si no reconoces alguno, bórralo en Ajustes › General › VPN y gestión de dispositivos.")
                        Check(ok: s.sideloaded.isEmpty, title: s.sideloaded.isEmpty ? "Todas las apps vienen del App Store" : "\(s.sideloaded.count) app(s) fuera del App Store",
                              detail: "Las apps de empresa, de desarrollo o de tiendas alternativas no pasan la revisión de Apple.")
                        Check(ok: s.traffic.isEmpty, warn: false, title: s.traffic.isEmpty ? "Ninguna app puede desviar tu tráfico" : "\(s.traffic.count) app(s) pueden ver o desviar tu tráfico",
                              detail: "Pueden crear una VPN, un filtro de contenido o un proxy DNS. Es normal en apps de VPN, antivirus o control parental; desconfía si no sabes por qué la tiene.")
                        if let dev = agent.info?.developerMode {
                            Check(ok: !dev, warn: false, title: dev ? "Modo de desarrollador activado" : "Modo de desarrollador desactivado",
                                  detail: dev ? "Lo necesitan CPU, procesos, pantalla y ubicación de esta app. Desactívalo en Ajustes › Privacidad y seguridad si no lo usas."
                                      : "Más seguro, pero esta app no puede mostrar CPU, procesos, pantalla ni simular ubicación.")
                        }
                    }
                    if !s.profiles.isEmpty {
                        Section("Perfiles de configuración") {
                            ForEach(s.profiles) { p in
                                HStack {
                                    VStack(alignment: .leading) {  // names often carry a person's name or ID number: hidden in privacy mode
                                        Text(agent.privacy ? "Perfil" : p.name)
                                        Text(agent.masked(p.id)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                    Spacer()
                                    if !p.active { Text("inactivo").foregroundStyle(.secondary) }
                                    if !p.removable { Text("no se puede eliminar").font(.caption.bold()).foregroundStyle(.orange) }
                                }
                            }
                        }
                    }
                    notes("Apps que pueden ver o desviar tu tráfico", s.traffic)
                    notes("Apps instaladas fuera del App Store (firmante)", s.sideloaded)
                }
            } else {
                ProgressView("Revisando perfiles y apps…")
            }
        }
        .toolbar {
            Button { agent.security = nil; agent.send(["cmd": "security"]) } label: { Label("Actualizar", systemImage: "arrow.clockwise") }
        }
        .task { if agent.security == nil { agent.send(["cmd": "security"]) } }
    }

    @ViewBuilder private func notes(_ title: String, _ apps: [SecurityReport.AppNote]) -> some View {
        if !apps.isEmpty {
            Section(title) {
                ForEach(apps) { a in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(a.name)
                            Text(a.bundle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(a.detail).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// One line of the security summary: green when fine, orange (or blue for "worth knowing") otherwise.
private struct Check: View {
    let ok: Bool
    var warn = true
    let title: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: ok ? "checkmark.shield.fill" : warn ? "exclamationmark.shield.fill" : "info.circle.fill")
                .foregroundStyle(ok ? .green : warn ? .orange : .blue)
                .font(.title3)
        }
        .padding(.vertical, 4)
    }
}
