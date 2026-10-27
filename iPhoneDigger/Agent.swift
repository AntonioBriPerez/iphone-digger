import AppKit
import CoreLocation
import Foundation
import Observation
import UserNotifications

// MARK: - Events sent by agent/agent.py (one JSON object per line)

struct DeviceRef: Decodable, Hashable {
    let udid: String
    let conn: String
}

struct DeviceInfo: Decodable {
    let udid, name, model, ios: String
    let storageTotal, storageFree: Double
    let developerMode: Bool?
    let fields: [[String]]
}

struct Battery: Decodable {
    let level: Int?
    let charging, external: Bool?
    let cycles, voltageMv, amperageMa: Int?
    let tempC: Double?
    let designMah, maxMah, remainingMah, timeToEmptyMin: Int?
    let systemLoadMw, powerInMw, batteryPowerMw: Int?

    var health: Double? {
        guard let d = designMah, let m = maxMah, d > 0 else { return nil }
        return Double(m) / Double(d) * 100
    }
}

struct SystemSample: Decodable {
    let cpu: Double?
    let perCpu: [Double]
    let memTotal, memUsed, memFree: Double
    let threads: Int?
    let rates: [String: Double]
}

struct Proc: Decodable, Identifiable {
    let pid: Int
    let name: String
    let cpu, mem: Double
    let threads: Int?
    let power, diskW: Double
    var id: Int { pid }
}

struct LogLine: Decodable, Identifiable {
    var id = 0
    let ts: String
    let pid: Int
    let proc, level, msg: String
    let sub, cat: String?
    enum CodingKeys: String, CodingKey { case ts, pid, proc, level, msg, sub, cat }

    /// Same ranks as LEVEL_RANK in agent.py.
    var rank: Int { ["DEBUG": 0, "INFO": 1, "ERROR": 3, "FAULT": 4][level] ?? 2 }
}

struct AppItem: Decodable, Identifiable {
    let bundle, name: String
    let version: String?
    let staticSize, dynamicSize: Double
    let background, permissions: [String]
    let sharing: Bool?
    var id: String { bundle }
    var total: Double { staticSize + dynamicSize }
    enum CodingKeys: String, CodingKey {
        case bundle, name, version, background, permissions, sharing
        case staticSize = "static", dynamicSize = "dynamic"
    }
}

/// Traffic between one process and one remote address, accumulated since the Network page was first opened.
struct NetFlow: Decodable, Identifiable {
    let proc, ip, host: String
    let ports: [Int]
    let rx, tx: Double
    let packets: Int
    let last: Double
    var id: String { proc + "|" + ip }
    var total: Double { rx + tx }
    var app: String { proc == "?" ? "Sistema" : proc }
    var destination: String { host.isEmpty ? ip : host }
}

struct SecurityReport: Decodable {
    struct Profile: Decodable, Identifiable { let id, name: String; let removable, active: Bool }
    struct AppNote: Decodable, Identifiable { let name, bundle, detail: String; var id: String { bundle } }
    let supervised: Bool?
    let profiles: [Profile]
    let sideloaded, traffic: [AppNote]
}

struct RemoteFile: Decodable, Identifiable, Hashable {
    let name: String
    let dir: Bool
    let size, mtime: Double
    var id: String { name }
}

/// One battery sample kept on disk so the Battery page can show hours and days, not just this session.
struct BatteryRecord: Identifiable {
    let date: Date
    let level: Int
    let plugged: Bool
    let loadMw: Int?
    let tempC: Double?
    let topProc: String
    var id: Date { date }

    var csv: String {
        [String(Int(date.timeIntervalSince1970)), String(level), plugged ? "1" : "0", loadMw.map(String.init) ?? "",
         tempC.map { String(format: "%.1f", $0) } ?? "", topProc.replacingOccurrences(of: ",", with: " ")].joined(separator: ",")
    }
}

extension BatteryRecord {
    init?(csv line: Substring) {
        let f = line.split(separator: ",", omittingEmptySubsequences: false)
        guard f.count == 6, let t = Double(f[0]), let level = Int(f[1]) else { return nil }
        self.init(date: Date(timeIntervalSince1970: t), level: level, plugged: f[2] == "1", loadMw: Int(f[3]), tempC: Double(f[4]), topProc: String(f[5]))
    }
}

struct Point: Identifiable {
    let id: Int
    let date: Date
    let value: Double
}

private struct Envelope: Decodable { let t: String }
private struct Items<T: Decodable>: Decodable { let items: [T] }
private struct Logs: Decodable { let items: [LogLine]; let dropped: Int; let rate: Int? }
private struct Dev: Decodable { let status: String; let msg: String? }
private struct Crash: Decodable { let path, text: String }
private struct Shot: Decodable { let png: String }
private struct AgentError: Decodable { let `where`: String; let msg: String }
private struct Files: Decodable { let bundle, dir: String; let items: [RemoteFile]; let msg: String }
private struct Pcap: Decodable { let on: Bool; let packets: Int; let path: String }
private struct Location: Decodable { let lat, lon: Double? }

/// Shows crash notifications even while the app is in front (macOS hides them by default).
private final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Turns the agent's stdout chunks into complete lines. Only touched from the pipe's serial handler queue.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()

    func feed(_ data: Data) -> [Data] {
        var from = buffer.endIndex  // only new bytes can hold an unseen newline; rescanning made big lines quadratic
        buffer.append(data)
        var start = buffer.startIndex, lines: [Data] = []
        while let nl = buffer[from...].firstIndex(of: 0x0A) {
            lines.append(Data(buffer[start..<nl]))
            start = nl + 1
            from = start
        }
        buffer.removeSubrange(buffer.startIndex..<start)
        return lines
    }
}

// MARK: - Bridge to the Python agent

@MainActor @Observable
final class Agent {
    var devices: [DeviceRef] = []
    var info: DeviceInfo?
    var battery: Battery?
    var system: SystemSample?
    var procs: [Proc] = []
    var logs: [LogLine] = []
    var logsDropped = 0
    var logRate = 0
    var apps: [AppItem]?
    var crashes: [String]?
    var crash: (path: String, text: String)?
    var screenshot: NSImage?
    var devStatus = "conectando"
    var devMessage: String?
    var lastError: String?
    var missingPython = false
    var cpuHistory: [Point] = []
    var memHistory: [Point] = []
    var netInHistory: [Point] = []
    var netOutHistory: [Point] = []
    var powerHistory: [Point] = []
    var net: [NetFlow] = []
    var pcap: (on: Bool, packets: Int, path: String)?
    var security: SecurityReport?
    var files: (bundle: String, dir: String, items: [RemoteFile])?
    var filesBusy = false
    var fileMessage: String?
    var simulatedLocation: CLLocationCoordinate2D?
    var batteryLog: [BatteryRecord] = []
    var perfLog: [String]?  // CSV rows while a performance session is being recorded
    private var knownCrashes: Set<String>?
    private var lastNotified: [String: Date] = [:]

    /// Hides identifiers (serial, UDID, IMEI, phone, MACs, device name) so screenshots can be shared.
    var privacy = UserDefaults.standard.bool(forKey: "privacy") { didSet { UserDefaults.standard.set(privacy, forKey: "privacy") } }
    static let sensitiveFields: Set<String> = ["Nombre", "Número de serie", "UDID", "MAC Wi-Fi", "MAC Bluetooth", "Teléfono", "IMEI", "IMEI 2"]

    func masked(_ value: String, label: String = "Nombre") -> String {
        privacy && Self.sensitiveFields.contains(label) ? String(repeating: "•", count: min(max(value.count, 6), 17)) : value
    }
    var deviceName: String { privacy ? "iPhone" : info?.name ?? "" }
    var liveScreen = false { didSet { send(["cmd": "live_screen", "on": liveScreen]) } }
    // Log filters run in the agent too, so the per-flush cap only ever drops lines that would be shown.
    var logMinLevel = UserDefaults.standard.object(forKey: "logMinLevel") as? Int ?? 2 {  // hide info/debug by default, like Console
        didSet { UserDefaults.standard.set(logMinLevel, forKey: "logMinLevel"); sendLogFilter() }
    }
    var logMuted = Set(UserDefaults.standard.stringArray(forKey: "logMuted") ?? []) {
        didSet { UserDefaults.standard.set(logMuted.sorted(), forKey: "logMuted"); sendLogFilter() }
    }
    var logOnly = "" { didSet { sendLogFilter() } }

    func logPasses(_ l: LogLine) -> Bool {
        l.rank >= logMinLevel && !logMuted.contains(l.proc) && (logOnly.isEmpty || l.proc == logOnly)
    }

    private func sendLogFilter() {
        send(["cmd": "log_filter", "min_level": logMinLevel, "muted": logMuted.sorted(), "only": logOnly])
    }

    private var process: Process?
    private var seq = 0
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let historyLength = 120
    static let logLimit = 3000

    /// Python with pymobiledevice3 installed: explicit override, the venv created by setup.sh, or an existing pipx install.
    static func pythonPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            ProcessInfo.processInfo.environment["IPHONE_DIGGER_PYTHON"],
            home + "/Library/Application Support/iPhoneDigger/venv/bin/python3",
            home + "/Library/Application Support/pipx/venvs/pymobiledevice3/bin/python",
            home + "/.local/pipx/venvs/pymobiledevice3/bin/python",
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() {
        guard process == nil else { return }
        guard let python = Self.pythonPath(), let script = Bundle.main.path(forResource: "agent", ofType: "py") else {
            missingPython = true
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-I", script]
        let out = Pipe(), inp = Pipe(), errPipe = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = errPipe
        let splitter = LineSplitter()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            // Split off the main thread: a screenshot is a multi-MB line that arrives in dozens of chunks.
            let lines = splitter.feed(h.availableData)
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { lines.forEach { self?.handle($0) } } }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.lastError = s.trimmingCharacters(in: .whitespacesAndNewlines) } }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    self?.process = nil
                    self?.start()  // the agent died (crash or device glitch): bring it back
                }
            }
        }
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        do {
            try p.run()
            process = p
            sendLogFilter()
        } catch {
            lastError = "No se pudo lanzar el agente: \(error.localizedDescription)"
        }
    }

    func stop() {
        if simulatedLocation != nil {  // don't leave the phone stuck at a fake position after quitting
            send(["cmd": "location"])
            Thread.sleep(forTimeInterval: 0.5)
        }
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    func send(_ cmd: [String: Any]) {
        guard let pipe = process?.standardInput as? Pipe,
              var data = try? JSONSerialization.data(withJSONObject: cmd) else { return }
        data.append(0x0A)
        try? pipe.fileHandleForWriting.write(contentsOf: data)
    }

    func select(_ udid: String) {
        resetDeviceState()
        send(["cmd": "select", "udid": udid])
    }

    private func resetDeviceState() {
        info = nil; battery = nil; system = nil; procs = []; logs = []; apps = nil; crashes = nil; crash = nil
        screenshot = nil; devStatus = "conectando"; devMessage = nil
        cpuHistory = []; memHistory = []; netInHistory = []; netOutHistory = []; powerHistory = []
        net = []; pcap = nil; security = nil; files = nil; filesBusy = false; fileMessage = nil
        simulatedLocation = nil; batteryLog = []; perfLog = nil; knownCrashes = nil
    }

    func fileOp(_ bundle: String, _ op: String, path: String, local: String = "") {
        filesBusy = true
        send(["cmd": "files", "bundle": bundle, "op": op, "path": path, "local": local])
    }

    // MARK: Battery history (one CSV per iPhone in Application Support)

    /// Daemons busy because this app is measuring the phone (stats, live logs, screenshots); they would top every energy ranking.
    static func isInstrumentation(_ name: String) -> Bool {
        ["sysmond", "DTServiceHub", "diagnosticd"].contains(name) || name.hasPrefix("com.apple.dt.")
    }

    static let historyWindow: TimeInterval = 30 * 86400
    private var batteryFile: URL? {
        info.map { URL.applicationSupportDirectory.appending(path: "iPhoneDigger/battery-\($0.udid).csv") }
    }

    private func loadBatteryLog() {
        let cutoff = Date.now.addingTimeInterval(-Self.historyWindow)
        let text = batteryFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        batteryLog = text.split(separator: "\n").compactMap(BatteryRecord.init(csv:)).filter { $0.date > cutoff }
        if let url = batteryFile, batteryLog.count < text.count(where: { $0 == "\n" }) {  // drop expired lines
            try? (batteryLog.map(\.csv).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func recordBattery(_ b: Battery) {
        guard let url = batteryFile, let level = b.level,
              Date.now.timeIntervalSince(batteryLog.last?.date ?? .distantPast) >= 30 else { return }
        let r = BatteryRecord(date: .now, level: level, plugged: b.external == true, loadMw: b.systemLoadMw, tempC: b.tempC,
                              topProc: procs.filter { !Self.isInstrumentation($0.name) }.max { $0.power < $1.power }?.name ?? "")
        batteryLog.append(r)
        let line = Data((r.csv + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
            try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: url)
        }
    }

    // MARK: Performance session recording

    static let perfHeader = "hora,cpu_%,memoria_gb,red_bajada_kbs,red_subida_kbs,disco_lectura_kbs,disco_escritura_kbs,consumo_mw,bateria_%,proceso_top_cpu,cpu_proceso_top_%"

    private func recordPerf(_ s: SystemSample) {
        let top = procs.max { $0.cpu < $1.cpu }
        let r = s.rates
        perfLog?.append([
            Date.now.ISO8601Format(.iso8601(timeZone: .current)), String(format: "%.1f", s.cpu ?? 0), String(format: "%.2f", s.memUsed / 1_073_741_824),
            String(format: "%.1f", (r["netBytesIn"] ?? 0) / 1024), String(format: "%.1f", (r["netBytesOut"] ?? 0) / 1024),
            String(format: "%.1f", (r["diskBytesRead"] ?? 0) / 1024), String(format: "%.1f", (r["diskBytesWritten"] ?? 0) / 1024),
            battery?.systemLoadMw.map(String.init) ?? "", battery?.level.map(String.init) ?? "",
            (top?.name ?? "").replacingOccurrences(of: ",", with: " "), String(format: "%.1f", top?.cpu ?? 0),
        ].joined(separator: ","))
    }

    // MARK: Crash notifications

    private func notifyNewCrashes(_ paths: Set<String>) {
        // At most one notification per process every 6 h: some apps crash on a loop (a watch app every 20 min).
        let reports = paths.map(CrashReport.init).filter {
            $0.kind.worthNotifying && Date.now.timeIntervalSince(lastNotified[$0.process] ?? .distantPast) > 6 * 3600
        }
        guard !reports.isEmpty else { return }
        reports.forEach { lastNotified[$0.process] = .now }
        let c = UNMutableNotificationContent()
        c.title = reports.count == 1 ? "Nuevo fallo en el iPhone" : "\(reports.count) fallos nuevos en el iPhone"
        c.body = reports.prefix(3).map { "\($0.process): \($0.kind.title.lowercased())" }.joined(separator: "\n")
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    private func push(_ history: inout [Point], _ value: Double) {
        seq += 1
        history.append(Point(id: seq, date: .now, value: value))
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    private func handle(_ line: Data) {
        guard let t = try? decoder.decode(Envelope.self, from: line).t else { return }
        do {
            switch t {
            case "devices":
                let new = try decoder.decode(Items<DeviceRef>.self, from: line).items
                if !new.contains(where: { $0.udid == info?.udid }) { resetDeviceState() }
                devices = new
            case "info":
                info = try decoder.decode(DeviceInfo.self, from: line)
                loadBatteryLog()
            case "battery":
                let b = try decoder.decode(Battery.self, from: line)
                battery = b
                if let mw = b.systemLoadMw { push(&powerHistory, Double(mw)) }
                recordBattery(b)
            case "system":
                let s = try decoder.decode(SystemSample.self, from: line)
                system = s
                recordPerf(s)
                push(&cpuHistory, s.cpu ?? 0)
                push(&memHistory, s.memUsed / 1_073_741_824)
                if let i = s.rates["netBytesIn"], let o = s.rates["netBytesOut"] {
                    push(&netInHistory, i / 1024)
                    push(&netOutHistory, o / 1024)
                }
            case "procs":
                procs = try decoder.decode(Items<Proc>.self, from: line).items
            case "logs":
                let l = try decoder.decode(Logs.self, from: line)
                logsDropped += l.dropped
                logRate = l.rate ?? 0
                for var item in l.items {
                    seq += 1
                    item.id = seq
                    logs.append(item)
                }
                if logs.count > Self.logLimit { logs.removeFirst(logs.count - Self.logLimit) }
            case "dev":
                let d = try decoder.decode(Dev.self, from: line)
                devStatus = d.status
                devMessage = d.msg
            case "apps":
                apps = try decoder.decode(Items<AppItem>.self, from: line).items
            case "crashes":
                let items = try decoder.decode(Items<String>.self, from: line).items
                crashes = items
                if let known = knownCrashes { notifyNewCrashes(Set(items).subtracting(known)) }
                knownCrashes = Set(items)
            case "net":
                net = try decoder.decode(Items<NetFlow>.self, from: line).items
            case "pcap":
                let p = try decoder.decode(Pcap.self, from: line)
                if pcap?.on == true && !p.on { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) }
                pcap = (p.on, p.packets, p.path)
            case "security":
                security = try decoder.decode(SecurityReport.self, from: line)
            case "files":
                let f = try decoder.decode(Files.self, from: line)
                files = (f.bundle, f.dir, f.items)
                filesBusy = false
                if !f.msg.isEmpty { fileMessage = f.msg }
            case "location":
                let l = try decoder.decode(Location.self, from: line)
                simulatedLocation = l.lat.flatMap { lat in l.lon.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) } }
            case "crash":
                let c = try decoder.decode(Crash.self, from: line)
                crash = (c.path, c.text)
            case "screenshot":
                let s = try decoder.decode(Shot.self, from: line)
                if let data = Data(base64Encoded: s.png) { screenshot = NSImage(data: data) }
            case "error":
                let e = try decoder.decode(AgentError.self, from: line)
                lastError = "\(e.where): \(e.msg)"
                if e.where == "files" { filesBusy = false; fileMessage = "Error: \(e.msg)" }
            default:
                break
            }
        } catch {
            lastError = "Evento '\(t)' ilegible: \(error)"
        }
    }
}
