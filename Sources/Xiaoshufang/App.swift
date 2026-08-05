import SwiftUI
import CoreBluetooth
import Foundation

// MARK: - V3 Protocol (谜姬 XHTKJ)
enum V3Proto {
    static let serviceUUID = CBUUID(string: "0000ff10-0000-1000-8000-00805f9b34fb")
    static let txUUID = CBUUID(string: "0000ff12-0000-1000-8000-00805f9b34fb")
    static let devicePrefix = "XHTKJ"
    static let fill: [UInt8] = [0x00, 0xfc, 0x00, 0xfe, 0x40, 0x01]

    /// speed 0-100 → 20 字节 BLE 包
    static func cmd(speed: Int) -> Data {
        if speed <= 0 {
            return Data([0x03, 0x12, 0xf3] + fill + [0x3c, 0x00] + fill + [0x3c, 0x00, 0x00])
        }
        let s = Double(speed) * 10          // 0-100 → 0-1000
        let scale = s / 1000.0 * 0.7 + 0.3
        let v = Int((scale * 1023).rounded())
        let modded = ((v << 6) | 60) & 0xFFFF
        let lo = UInt8(modded & 0xFF)
        let hi = UInt8((modded >> 8) & 0xFF)
        return Data([0x03, 0x12, 0xf3] + fill + [lo, hi] + fill + [lo, hi, 0x00])
    }
}

// MARK: - Bluetooth Manager
final class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status: String = "等待"
    @Published var connected = false
    @Published var deviceName: String = ""

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var lastCmd: Data = Data()
    private var keepTimer: Timer?
    private var reconnecting = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.xingxing.shufang"])
    }

    // — Central —
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        DispatchQueue.main.async {
            switch c.state {
            case .poweredOn: self.status = "搜索中…"; c.scanForPeripherals(withServices: nil)
            case .poweredOff: self.status = "蓝牙关了"
            case .unauthorized: self.status = "没授权"
            default: self.status = "蓝牙未就绪"
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? ""
        guard name.hasPrefix(V3Proto.devicePrefix) else { return }
        c.stopScan()
        peripheral = p
        p.delegate = self
        c.connect(p)
        DispatchQueue.main.async { self.status = "连接中…"; self.deviceName = name }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([V3Proto.serviceUUID])
        DispatchQueue.main.async { self.status = "已连接 · \(p.name ?? "")"; self.connected = true }
    }

    // — Peripheral —
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for svc in p.services ?? [] where svc.uuid == V3Proto.serviceUUID {
            p.discoverCharacteristics([V3Proto.txUUID], for: svc)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] where ch.uuid == V3Proto.txUUID {
            writeChar = ch
            startKeep()
            DispatchQueue.main.async { self.status = "就绪" }
        }
    }

    func peripheral(_ p: CBPeripheral, didDisconnectFrom error: Error?) {
        keepTimer?.invalidate()
        DispatchQueue.main.async { self.connected = false; self.status = "断了，重连…" }
        reconnect()
    }

    // — 写命令 —
    func vibrate(speed: Int) {
        guard let p = peripheral, let c = writeChar else { return }
        let d = V3Proto.cmd(speed: max(0, min(100, speed)))
        lastCmd = d
        p.writeValue(d, for: c, type: .withoutResponse)
    }

    func stop() {
        vibrate(speed: 0)
        lastCmd = V3Proto.cmd(speed: 0)
    }

    // — 200ms 保活重发 —
    private func startKeep() {
        keepTimer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, !self.lastCmd.isEmpty,
                  let p = self.peripheral, let c = self.writeChar else { return }
            p.writeValue(self.lastCmd, for: c, type: .withoutResponse)
        }
        RunLoop.main.add(t, forMode: .common)
        keepTimer = t
    }

    // — 自动重连 —
    private func reconnect() {
        guard !reconnecting, let p = peripheral else { return }
        reconnecting = true
        for i in 0..<10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(min(0.6 + Double(i) * 0.3, 3.5))) {
                guard self.reconnecting else { return }
                self.central.connect(p)
            }
        }
        reconnecting = false
    }

    // — 后台恢复 —
    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = ps.first {
            peripheral = p
            p.delegate = self
            if p.state == .connected {
                p.discoverServices([V3Proto.serviceUUID])
                DispatchQueue.main.async { self.status = "恢复连接"; self.connected = true }
            }
        }
    }
}

// MARK: - Command Poller
final class CommandPoller: ObservableObject {
    @Published var lastCmd: String = "—"
    @Published var bridgeAge: String = "—"

    private var timer: DispatchSourceTimer?
    private var pollSeq = 0
    private let base = "https://kiss.eoty.cn/toy-api"
    private let token = "xingxing-toy-2026"
    private weak var bt: BluetoothManager?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var patternItems: [DispatchWorkItem] = []

    func attach(_ bt: BluetoothManager) { self.bt = bt }

    func start() {
        poll()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1.5, repeating: 1.5)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    func enterBackground() {
        bgTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackground()
        }
    }

    func endBackground() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    private func poll() {
        guard let url = URL(string: "\(base)/cmd-poll?token=\(token)") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self.handle(json)
        }.resume()
    }

    private func handle(_ json: [String: Any]) {
        // 桥心跳
        if let age = json["bridge_ack_age"] as? Double {
            DispatchQueue.main.async {
                self.bridgeAge = age < 60 ? "\(Int(age))s" : "离线"
            }
        } else {
            DispatchQueue.main.async { self.bridgeAge = "—" }
        }

        // 命令队列
        guard let queueNow = json["queue_now"] as? Int, queueNow > pollSeq,
              let recent = json["queue_recent"] as? [[String: Any]] else { return }

        for item in recent {
            guard let seq = item["seq"] as? Int, seq > pollSeq else { continue }
            pollSeq = seq
            guard let type = item["cmd"] as? String else { continue }
            let args = item["args"] as? [String: Any] ?? [:]
            DispatchQueue.main.async { self.lastCmd = "\(type) \(args)" }
            execute(type, args)
        }
    }

    private func execute(_ type: String, _ args: [String: Any]) {
        // 新命令来了，取消旧的 pattern 序列
        patternItems.forEach { $0.cancel() }
        patternItems.removeAll()

        switch type {
        case "vibrate":
            let speed = num(args, "speed", 20)
            let dur = num(args, "duration", 5)
            bt?.vibrate(speed: Int(speed))
            let w = DispatchWorkItem { [weak self] in self?.bt?.stop() }
            patternItems.append(w)
            DispatchQueue.main.asyncAfter(deadline: .now() + dur, execute: w)

        case "stop":
            bt?.stop()

        case "pattern":
            guard let pat = args["pattern"] as? String else { return }
            let speeds = pat.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let iv = num(args, "interval", 0.9)
            let loops = Int(num(args, "loops", 4))
            var all: [Int] = []
            for _ in 0..<loops { all.append(contentsOf: speeds) }
            for (i, sp) in all.enumerated() {
                let w = DispatchWorkItem { [weak self] in self?.bt?.vibrate(speed: sp) }
                patternItems.append(w)
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * iv, execute: w)
            }
            let stop = DispatchWorkItem { [weak self] in self?.bt?.stop() }
            patternItems.append(stop)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(all.count) * iv + 1, execute: stop)

        case "ping": break
        default: break
        }
    }

    private func num(_ args: [String: Any], _ key: String, _ def: Double) -> Double {
        if let d = args[key] as? Double { return d }
        if let i = args[key] as? Int { return Double(i) }
        return def
    }
}

// MARK: - UI
struct ContentView: View {
    @Environment(\.scenePhase) var scenePhase
    @StateObject private var bt = BluetoothManager()
    @StateObject private var poller = CommandPoller()

    var body: some View {
        VStack(spacing: 24) {
            // 状态
            VStack(spacing: 8) {
                Circle()
                    .fill(bt.connected ? Color(red: 0.43, green: 0.49, blue: 0.39) : Color(red: 0.79, green: 0.44, blue: 0.44))
                    .frame(width: 12, height: 12)
                    .shadow(color: bt.connected ? .green.opacity(0.3) : .red.opacity(0.3), radius: 4)
                Text(bt.status)
                    .font(.system(size: 14))
                    .foregroundColor(Color(red: 0.24, green: 0.22, blue: 0.20))
            }
            .padding(.top, 40)

            // 桥信息
            HStack(spacing: 12) {
                Text("桥").font(.system(size: 12)).foregroundColor(Color(red: 0.55, green: 0.51, blue: 0.46))
                Text(poller.bridgeAge).font(.system(size: 12, design: .monospaced))
                    .foregroundColor(poller.bridgeAge == "—" ? .secondary : Color(red: 0.79, green: 0.44, blue: 0.44))
                Spacer()
                Text(poller.lastCmd).font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(red: 0.96, green: 0.94, blue: 0.91))
            .cornerRadius(12)

            Spacer()

            // 手动控制
            HStack(spacing: 12) {
                ForEach([15, 30, 50, 80], id: \.self) { speed in
                    Button("\(speed)") {
                        bt.vibrate(speed: speed)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color(red: 0.79, green: 0.44, blue: 0.44))
                }
            }
            Button("停") { bt.stop() }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.54, green: 0.23, blue: 0.23))
                .padding(.bottom, 30)
        }
        .padding()
        .background(Color(red: 0.98, green: 0.97, blue: 0.95).ignoresSafeArea())
        .onAppear {
            poller.attach(bt)
            poller.start()
        }
        .onDisappear { poller.stop() }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background: poller.enterBackground()
            case .active: poller.endBackground()
            default: break
            }
        }
    }
}

// MARK: - App
@main
struct XiaoshufangApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
