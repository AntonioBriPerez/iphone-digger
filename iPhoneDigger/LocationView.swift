import MapKit
import SwiftUI

/// Move the iPhone's GPS position to any point on the map (Developer Mode), and back.
struct LocationView: View {
    @Environment(Agent.self) private var agent
    @State private var position: MapCameraPosition = .automatic
    @State private var query = ""
    @State private var region: MKCoordinateRegion?

    var body: some View {
        VStack(spacing: 0) {
            DeveloperBanner().padding([.horizontal, .top], 12)
            MapReader { proxy in
                Map(position: $position) {
                    if let c = agent.simulatedLocation {
                        Marker("iPhone", systemImage: "iphone", coordinate: c).tint(.red)
                    }
                }
                .onMapCameraChange { region = $0.region }
                .onTapGesture { point in
                    guard let c = proxy.convert(point, from: .local) else { return }
                    if let region { position = .region(region) }  // pin the view: .automatic would zoom right into the new marker
                    set(c)
                }
            }
            HStack {
                if let c = agent.simulatedLocation {
                    Image(systemName: "location.fill").foregroundStyle(.red)
                    Text("El iPhone cree que está en \(c.latitude, format: .number.precision(.fractionLength(5))), \(c.longitude, format: .number.precision(.fractionLength(5)))")
                        .textSelection(.enabled)
                    Spacer()
                    Button("Volver a la ubicación real") {
                        if let region { position = .region(region) }
                        agent.send(["cmd": "location"])
                    }
                } else {
                    Image(systemName: "hand.tap").foregroundStyle(.secondary)
                    Text("Pulsa en el mapa o busca un lugar para mover el GPS del iPhone ahí. Las apps verán esa ubicación hasta que vuelvas a la real o cierres esta app.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(12)
            .background(.bar)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Buscar un lugar")
        .onSubmit(of: .search) { Task { await search() } }
    }

    private func set(_ c: CLLocationCoordinate2D) {
        agent.send(["cmd": "location", "lat": c.latitude, "lon": c.longitude])
    }

    private func search() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return }
        let c = if #available(macOS 26, *) { item.location.coordinate } else { item.placemark.coordinate }
        position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 3000, longitudinalMeters: 3000))
        set(c)
    }
}
