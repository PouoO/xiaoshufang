import SwiftUI
import CoreBluetooth
import Foundation

// MARK: - V3 Protocol (谜姬 XHTKJ)
enum V3Proto {
    static let serviceUUID = CBUUID(string: "0000ff10-0000-1000-8000-00805f9b34fb")
    static let txUUID = CBUUID(string: "0000ff12-0000-1000-8000-00805f9b34fb")
    static let fill: [UInt8] = [0x00, 0xfc, 0x00, 0xfe, 0x40, 0x01]

    static func cmd(speed: Int) -> Data {
        if speed <= 0 {
            return Data([0x03, 0x12, 0xf3] + fill + [0x3c, 0x00] + fill + [0x3c, 0x00, 0x00])
        }
        let s = Double(speed) * 10
        let scale = s / 1000.0 * 0.7 + 0.3
        let v = Int((scale * 1023).rounded())
        let modded = ((v << 6) | 60) & 0xFFFF
        let lo = UInt8(modded & 0xFF)
        let hi = UInt8((modded >> 8) & 0xFF)
        return Data([0x03, 0x12, 0xf3] + fill + [lo, hi] + fill + [lo, hi, 0x00])
    }
}

// MARK: - Discovered Device
struct DiscoveredDevice: Identifiable {
    let id = UUID()
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    let services: [String]
}

// MARK: - Bluetooth Manager
final class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status: String = "初始化…"
    @Published var connected = false
    @Published var deviceName: String = ""
    @Published var discovered: [DiscoveredDevice] = []
    @Published var logs: [String] = []
    @Published var bleReady = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var lastCmd: Data = Data()
    private var keepTimer: Timer?
    private var reconnecting = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.xingxing.shufang",
                      CBCentralManagerOptionShowPowerAlertKey: true])
    }

    private func log(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        DispatchQueue.main.async { self.logs.insert("\(ts) \(msg)", at: 0); if self.logs.count > 50 { self.logs = Array(self.logs.prefix(50)) } }
    }

    // — Central —
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        DispatchQueue.main.async {
            switch c.state {
            case .poweredOn:
                self.bleReady = true
                self.status = "搜索中…"
                self.log("蓝牙开了，开始扫描")
                self.startScan()
            case .poweredOff:
                self.bleReady = false
                self.status = "蓝牙关了"
                self.log("蓝牙关了")
            case .unauthorized:
                self.bleReady = false
                self.status = "没蓝牙权限"
                self.log("没蓝牙权限 — 设置→隐私→蓝牙")
            case .resetting:
                self.bleReady = false
                self.status = "蓝牙重置中"
            case .unsupported:
                self.bleReady = false
                self.status = "不支持蓝牙"
            case .unknown:
                self.bleReady = false
                self.status = "蓝牙状态未知"
            @unknown default:
                self.bleReady = false
                self.status = "蓝牙未知状态"
            }
        }
    }

    func startScan() {
        guard central.state == .poweredOn else { return }
        discovered.removeAll()
        log("扫描所有 BLE 设备…")
        // 全扫描 — 谜姬可能在广播包里不含 service UUID
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    func stopScan() {
        central.stopScan()
    }

    func rescan() {
        guard bleReady else { return }
        if peripheral != nil && connected {
            disconnect()
        }
        status = "搜索中…"
        startScan()
    }

    func connectToDevice(_ device: DiscoveredDevice) {
        central.stopScan()
        peripheral = device.peripheral
        peripheral?.delegate = self
        central.connect(device.peripheral)
        DispatchQueue.main.async {
            self.status = "连接中…"
            self.deviceName = device.name
        }
        log("手动连接: \(device.name) RSSI:\(device.rssi)")
    }

    func disconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        keepTimer?.invalidate()
        keepTimer = nil
        peripheral = nil
        writeChar = nil
        DispatchQueue.main.async {
            self.connected = false
            self.status = "已断开"
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // 优先从 advertisementData 取名字（iOS 扫描时 p.name 可能是 nil）
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "未知"
        let rssiVal = RSSI.intValue

        // 提取广播的 service UUIDs
        let svcUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString } ?? []
        let svcStrs = svcUUIDs.map { $0.prefix(8) }.map { String($0) }

        // 去重 — 同一个设备只显示一次（按 identifier）
        let dev = DiscoveredDevice(peripheral: p, name: name, rssi: rssiVal, services: svcStrs)
        DispatchQueue.main.async {
            // 如果这个设备已经在列表里，更新 RSSI
            if let idx = self.discovered.firstIndex(where: { $0.peripheral.identifier == p.identifier }) {
                self.discovered[idx] = dev
            } else {
                self.discovered.append(dev)
                self.log("发现: \(name) RSSI:\(rssiVal) svc:\(svcStrs)")
            }
        }

        // 自动匹配谜姬
        let isMizzzee = name.hasPrefix("XHTKJ") || name.hasPrefix("XHT") || name.hasPrefix("NFY")
        let hasService = svcUUIDs.contains { $0.isEqual(V3Proto.serviceUUID) }
        if isMizzzee || hasService {
            c.stopScan()
            peripheral = p
            p.delegate = self
            c.connect(p)
            DispatchQueue.main.async {
                self.status = "连接中…"
                self.deviceName = name
            }
            log("匹配到谜姬! \(name) — 自动连接")
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("已连接: \(p.name ?? "未知")")
        DispatchQueue.main.async { self.status = "发现服务中…"; self.connected = true }
        p.discoverServices([V3Proto.serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("连接失败: \(error?.localizedDescription ?? "未知错误")")
        DispatchQueue.main.async { self.status = "连接失败" }
    }

    // — Peripheral —
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { log("发现服务失败: \(e.localizedDescription)"); return }
        let svcs = p.services ?? []
        log("服务: \(svcs.map { $0.uuid.uuidString.prefix(8) })")
        for svc in svcs where svc.uuid == V3Proto.serviceUUID {
            p.discoverCharacteristics([V3Proto.txUUID], for: svc)
            log("找到 ff10 服务，找特征值…")
        }
        if !svcs.contains(where: { $0.uuid == V3Proto.serviceUUID }) {
            log("没找到 ff10 服务! 有的: \(svcs.map { $0.uuid.uuidString })")
            // 试着发现所有服务
            p.discoverServices(nil)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let e = error { log("发现特征值失败: \(e.localizedDescription)"); return }
        let chars = service.characteristics ?? []
        log("特征值: \(chars.map { $0.uuid.uuidString.prefix(8) })")
        for ch in chars where ch.uuid == V3Proto.txUUID {
            writeChar = ch
            startKeep()
            DispatchQueue.main.async { self.status = "就绪" }
            log("找到 ff12 特征值，就绪!")
        }
    }

    func peripheral(_ p: CBPeripheral, didDisconnectFrom error: Error?) {
        keepTimer?.invalidate()
        keepTimer = nil
        log("断开: \(error?.localizedDescription ?? "未知")")
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
        log("开始重连…")
        for i in 0..<10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(min(0.6 + Double(i) * 0.3, 3.5))) { [weak self] in
                guard let self = self, self.reconnecting, let p = self.peripheral else { return }
                if p.state != .connected {
                    self.central.connect(p)
                    self.log("重连第 \(i+1) 次…")
                }
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

    private var pollSeq = 0
    private let base = "https://kiss.eoty.cn/toy-api"
    private let token = "xingxing-toy-2026"
    private weak var bt: BluetoothManager?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var patternItems: [DispatchWorkItem] = []
    private var polling = false

    func attach(_ bt: BluetoothManager) { self.bt = bt }

    func start() {
        guard !polling else { return }
        polling = true
        longPoll()
    }

    func stop() { polling = false }

    func enterBackground() {
        bgTask = UIApplication.shared.beginBackgroundTask { [weak self] in self?.endBackground() }
    }

    func endBackground() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    private func longPoll() {
        guard polling else { return }
        guard let url = URL(string: "\(base)/wait?token=\(token)&since=\(pollSeq)&timeout=30") else {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.longPoll() }
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 35)
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, self.polling else { return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.longPoll() }
                return
            }
            self.handle(json)
            self.longPoll()
        }.resume()
    }

    private func handle(_ json: [String: Any]) {
        if let age = json["bridge_ack_age"] as? Double {
            DispatchQueue.main.async { self.bridgeAge = age < 60 ? "\(Int(age))s" : "离线" }
        } else {
            DispatchQueue.main.async { self.bridgeAge = "—" }
        }

        guard let cmds = json["commands"] as? [[String: Any]] else { return }

        for item in cmds {
            guard let seq = item["seq"] as? Int, seq > pollSeq else { continue }
            pollSeq = seq
            guard let type = item["cmd"] as? String else { continue }
            let args = item["args"] as? [String: Any] ?? [:]
            DispatchQueue.main.async { self.lastCmd = "\(type) \(args)" }
            execute(type, args)
        }
    }

    private func execute(_ type: String, _ args: [String: Any]) {
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
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // 状态卡片
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(bt.connected ? Color(red: 0.43, green: 0.49, blue: 0.39) : Color(red: 0.79, green: 0.44, blue: 0.44))
                                .frame(width: 10, height: 10)
                            Text(bt.status).font(.system(size: 14)).foregroundColor(Color(red: 0.24, green: 0.22, blue: 0.20))
                            Spacer()
                            Button(bt.bleReady ? "重新搜索" : "蓝牙未开") {
                                bt.rescan()
                            }
                            .disabled(!bt.bleReady)
                            .font(.system(size: 13))
                            .buttonStyle(.bordered)
                            .tint(Color(red: 0.79, green: 0.44, blue: 0.44))
                        }
                        HStack(spacing: 8) {
                            Text("桥").font(.system(size: 11)).foregroundColor(.secondary)
                            Text(poller.bridgeAge).font(.system(size: 11, design: .monospaced))
                                .foregroundColor(poller.bridgeAge == "—" ? .secondary : Color(red: 0.79, green: 0.44, blue: 0.44))
                            Spacer()
                            Text(poller.lastCmd).font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    .padding(14)
                    .background(Color(red: 0.96, green: 0.94, blue: 0.91))
                    .cornerRadius(12)

                    // 扫描到的设备
                    if !bt.discovered.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("扫描到的设备").font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(red: 0.55, green: 0.51, blue: 0.46))
                            ForEach(bt.discovered) { dev in
                                Button {
                                    bt.connectToDevice(dev)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(dev.name).font(.system(size: 13))
                                                .foregroundColor(.primary)
                                            Text("RSSI: \(dev.rssi)dBm \(dev.services.isEmpty ? "" : "svc: \(dev.services.joined(separator: ", "))")")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12)).foregroundColor(.secondary)
                                    }
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                        .padding(14)
                        .background(Color.white)
                        .cornerRadius(12)
                    }

                    // 手动控制（连上后显示）
                    if bt.connected {
                        VStack(spacing: 12) {
                            Text("手动控制").font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(red: 0.55, green: 0.51, blue: 0.46))
                            HStack(spacing: 10) {
                                ForEach([15, 30, 50, 80, 100], id: \.self) { speed in
                                    Button("\(speed)") { bt.vibrate(speed: speed) }
                                        .buttonStyle(.bordered)
                                        .tint(Color(red: 0.79, green: 0.44, blue: 0.44))
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            Button("停") { bt.stop() }
                                .buttonStyle(.borderedProminent)
                                .tint(Color(red: 0.54, green: 0.23, blue: 0.23))
                                .frame(maxWidth: .infinity)
                        }
                        .padding(14)
                        .background(Color.white)
                        .cornerRadius(12)
                    }

                    // 日志
                    if !bt.logs.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("日志").font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(red: 0.55, green: 0.51, blue: 0.46))
                            ForEach(bt.logs.prefix(15), id: \.self) { log in
                                Text(log).font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(14)
                        .background(Color.white)
                        .cornerRadius(12)
                    }
                }
                .padding()
            }
            .background(Color(red: 0.98, green: 0.97, blue: 0.95).ignoresSafeArea())
            .navigationTitle("小书房")
            .navigationBarTitleDisplayMode(.inline)
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
