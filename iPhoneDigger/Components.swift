import SwiftUI

func bytes(_ value: Double, _ style: ByteCountFormatter.CountStyle = .file) -> String {
    let f = ByteCountFormatter()
    f.countStyle = style
    f.allowsNonnumericFormatting = false  // "0 bytes", not "Zero KB"
    return f.string(fromByteCount: Int64(value))
}

func percent(_ value: Double?) -> String {
    value.map { String(format: "%.0f%%", $0) } ?? "—"
}

struct StatCard: View {
    let title: String
    let value: String
    var subtitle: String?
    let icon: String
    var tint: Color = .accentColor
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
            if let progress {
                ProgressView(value: min(max(progress, 0), 1)).tint(tint)
            }
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Shown on views that need Developer Mode (DVT services) when they are not available.
struct DeveloperBanner: View {
    @Environment(Agent.self) private var agent

    var body: some View {
        if agent.devStatus != "ok" {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Esta sección necesita los servicios de desarrollador").bold()
                    Text("Activa Ajustes › Privacidad y seguridad › Modo de desarrollador en el iPhone (y reinícialo). La app monta la imagen de desarrollador sola.")
                        .font(.caption)
                    if let m = agent.devMessage { Text(m).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                }
            } icon: {
                Image(systemName: "hammer").foregroundStyle(.orange)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
