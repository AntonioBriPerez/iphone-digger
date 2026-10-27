import AppKit
import Foundation
import Observation

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
    var id: String { bundle }
    var total: Double { staticSize + dynamicSize }
    enum CodingKeys: String, CodingKey {
        case bundle, name, version, background, permissions
        case staticSize = "static", dynamicSize = "dynamic"
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
        do {
            try p.run()
            process = p
            sendLogFilter()
        } catch {
            lastError = "No se pudo lanzar el agente: \(error.localizedDescription)"
        }
    }

    func stop() {
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
            case "battery":
                let b = try decoder.decode(Battery.self, from: line)
                battery = b
                if let mw = b.systemLoadMw { push(&powerHistory, Double(mw)) }
            case "system":
                let s = try decoder.decode(SystemSample.self, from: line)
                system = s
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
                crashes = try decoder.decode(Items<String>.self, from: line).items
            case "crash":
                let c = try decoder.decode(Crash.self, from: line)
                crash = (c.path, c.text)
            case "screenshot":
                let s = try decoder.decode(Shot.self, from: line)
                if let data = Data(base64Encoded: s.png) { screenshot = NSImage(data: data) }
            case "error":
                let e = try decoder.decode(AgentError.self, from: line)
                lastError = "\(e.where): \(e.msg)"
            default:
                break
            }
        } catch {
            lastError = "Evento '\(t)' ilegible: \(error)"
        }
    }
}
