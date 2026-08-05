import SwiftUI
import CoreBluetooth
import AVFoundation
import UniformTypeIdentifiers
import Foundation

// MARK: - 颜色
let C_BG     = Color(red: 0.976, green: 0.961, blue: 0.949)  // 奶霜 #F9F5F2
let C_BERRY  = Color(red: 0.851, green: 0.545, blue: 0.604)  // 莓粉 #D98B9A
let C_INK    = Color(red: 0.176, green: 0.141, blue: 0.141)  // 暖墨 #2D2424
let C_SKY    = Color(red: 0.545, green: 0.706, blue: 0.788)  // 奶蓝 #8BB4C9
let C_MUTE   = Color(red: 0.553, green: 0.510, blue: 0.459)  // 灰墨
let C_CARD   = Color.white
let C_INPUT  = Color(red: 0.965, green: 0.953, blue: 0.941)  // 输入框底

// MARK: - V3 Protocol (谜姬 XHTKJ)
enum V3Proto {
    static let serviceUUID = CBUUID(string: "0000ff10-0000-1000-8000-00805f9b34fb")
    static let txUUID = CBUUID(string: "0000ff12-0000-1000-8000-00805f9b34fb")
    static let devicePrefix = "XHTKJ"
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

// MARK: - 无声音乐保活
final class AudioKeeper {
    static let shared = AudioKeeper()
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
        player = try? AVAudioPlayer(data: Self.silenceWAV())
        player?.numberOfLoops = -1
        player?.volume = 0.01
        player?.play()
    }

    func stop() { player?.stop(); player = nil }

    private static func silenceWAV() -> Data {
        let sr = 44100, n = sr, ds = n * 2
        var d = Data()
        d.append("RIFF".data(using: .ascii)!); d.append(le32(ds + 36))
        d.append("WAVE".data(using: .ascii)!); d.append("fmt ".data(using: .ascii)!)
        d.append(le32(16)); d.append(le16(1)); d.append(le16(1))
        d.append(le32(sr)); d.append(le32(sr * 2)); d.append(le16(2)); d.append(le16(16))
        d.append("data".data(using: .ascii)!); d.append(le32(ds))
        d.append(Data(count: ds))
        return d
    }
    private static func le32(_ v: Int) -> Data { var x = UInt32(v); return withUnsafeBytes(of: &x) { Data($0) } }
    private static func le16(_ v: Int) -> Data { var x = UInt16(v); return withUnsafeBytes(of: &x) { Data($0) } }
}

// MARK: - 音乐播放
final class MusicPlayer: NSObject, ObservableObject {
    @Published var tracks: [String] = []
    @Published var currentIdx: Int? = nil
    @Published var isPlaying = false
    @Published var repeatMode: Int = 0  // 0=顺序, 1=单曲, 2=循环

    private var player: AVAudioPlayer?
    private let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private let exts: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "caf", "ogg"]

    override init() { super.init(); scan() }

    func scan() {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        tracks = items.filter { exts.contains($0.pathExtension.lowercased()) }
            .map { $0.lastPathComponent }
    }

    func play(_ idx: Int) {
        guard idx < tracks.count else { return }
        let url = dir.appendingPathComponent(tracks[idx])
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.numberOfLoops = (repeatMode == 1) ? -1 : 0
        player?.play()
        currentIdx = idx
        isPlaying = true
    }

    func toggle() {
        guard player != nil else { return }
        if isPlaying { player?.pause() } else { player?.play() }
        isPlaying.toggle()
    }

    func next() {
        guard let c = currentIdx, !tracks.isEmpty else { return }
        let n = (c + 1) % tracks.count
        play(n)
    }

    func cycleRepeat() { repeatMode = (repeatMode + 1) % 3 }

    func importFile(_ url: URL) {
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        try? FileManager.default.copyItem(at: url, to: dest)
        scan()
    }
}

extension MusicPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if repeatMode == 0 { DispatchQueue.main.async { self.next() } }
        else if repeatMode == 2 { DispatchQueue.main.async { if let i = self.currentIdx { self.play(i) } } }
        else { DispatchQueue.main.async { self.isPlaying = false } }
    }
}

// MARK: - Bluetooth Manager
final class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status: String = "等待"
    @Published var connected = false
    @Published var logs: [String] = []

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

    func rescan() {
        guard central.state == .poweredOn else { return }
        peripheral = nil
        writeChar = nil
        connected = false
        status = "搜索中…"
        central.scanForPeripherals(withServices: nil)
    }

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
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let svcUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let hasSvc = svcUUIDs.contains { $0.isEqual(V3Proto.serviceUUID) }
        guard name.hasPrefix("XHTKJ") || name.hasPrefix("XHT") || name.hasPrefix("NFY") || hasSvc else { return }
        c.stopScan()
        peripheral = p; p.delegate = self; c.connect(p)
        log("匹配到谜姬！\(name) - 自动连接")
        DispatchQueue.main.async { self.status = "连接中…" }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("已连接：\(p.name ?? "")")
        p.discoverServices([V3Proto.serviceUUID])
        DispatchQueue.main.async { self.status = "已连接"; self.connected = true }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { log("发现服务失败: \(e.localizedDescription)"); p.discoverServices(nil); return }
        let svcs = p.services ?? []
        log("服务：\(svcs.map { $0.uuid.uuidString })")
        for svc in svcs where svc.uuid.isEqual(V3Proto.serviceUUID) {
            log("找到 ff10 服务，找特征值…")
            p.discoverCharacteristics([V3Proto.txUUID], for: svc)
            return
        }
        // 没找到 ff10，发现所有
        for svc in svcs { p.discoverCharacteristics(nil, for: svc) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        log("特征值：\(chars.map { $0.uuid.uuidString })")
        for ch in chars where ch.uuid.isEqual(V3Proto.txUUID) {
            writeChar = ch
            startKeep()
            log("找到 ff12 特征值，就绪！")
            DispatchQueue.main.async { self.status = "就绪" }
            return
        }
        // 没找到 ff12，试所有可写的
        for ch in chars where ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) {
            writeChar = ch; startKeep()
            log("用 \(ch.uuid.uuidString) 作为写入特征值")
            DispatchQueue.main.async { self.status = "就绪" }
            return
        }
    }

    func peripheral(_ p: CBPeripheral, didDisconnectFrom error: Error?) {
        keepTimer?.invalidate(); keepTimer = nil
        log("断开: \(error?.localizedDescription ?? "未知")")
        DispatchQueue.main.async { self.connected = false; self.status = "重连中…" }
        reconnect()
    }

    func vibrate(speed: Int) {
        guard let p = peripheral, let c = writeChar else { return }
        let d = V3Proto.cmd(speed: max(0, min(100, speed)))
        lastCmd = d
        writeData(d, for: c)
    }

    func stop() {
        vibrate(speed: 0)
        lastCmd = V3Proto.cmd(speed: 0)
    }

    private func writeData(_ data: Data, for char: CBCharacteristic) {
        guard let p = peripheral else { return }
        if char.properties.contains(.writeWithoutResponse) {
            p.writeValue(data, for: char, type: .withoutResponse)
        } else {
            p.writeValue(data, for: char, type: .withResponse)
        }
    }

    private func startKeep() {
        keepTimer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, !self.lastCmd.isEmpty,
                  let p = self.peripheral, let c = self.writeChar else { return }
            self.writeData(self.lastCmd, for: c)
        }
        RunLoop.main.add(t, forMode: .common)
        keepTimer = t
    }

    private func reconnect() {
        guard !reconnecting, let p = peripheral else { return }
        reconnecting = true
        for i in 0..<20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(min(0.5 + Double(i) * 0.4, 5.0))) { [weak self] in
                guard let self = self, let p = self.peripheral else { return }
                if p.state != .connected { self.central.connect(p) }
            }
        }
        reconnecting = false
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = ps.first {
            peripheral = p; p.delegate = self
            if p.state == .connected {
                p.discoverServices([V3Proto.serviceUUID])
                DispatchQueue.main.async { self.status = "恢复"; self.connected = true }
            }
        }
    }

    private func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        DispatchQueue.main.async { self.logs.insert("\(f.string(from: Date())) \(s)", at: 0); if self.logs.count > 50 { self.logs.removeLast() } }
    }
}

// MARK: - Command Poller (long polling)
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
    private var ackTimer: DispatchSourceTimer?

    func attach(_ bt: BluetoothManager) { self.bt = bt }

    func start() {
        guard !polling else { return }
        polling = true
        // 拿当前 seq 跳过历史
        guard let url = URL(string: "\(base)/cmd-poll?token=\(token)") else { longPoll(); return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            if let self = self, let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let now = json["queue_now"] as? Int { self.pollSeq = now }
            self?.longPoll()
            self?.startAck()
        }.resume()
    }

    func stop() { polling = false; ackTimer?.cancel(); ackTimer = nil }

    func cancelAll() {
        patternItems.forEach { $0.cancel() }
        patternItems.removeAll()
    }

    func enterBackground() { bgTask = UIApplication.shared.beginBackgroundTask { [weak self] in self?.endBackground() } }
    func endBackground() { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid } }

    private func startAck() {
        sendAck()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in self?.sendAck() }
        t.resume(); ackTimer = t
    }
    private func sendAck() {
        guard let url = URL(string: "\(base)/ack") else { return }
        URLSession.shared.dataTask(with: url).resume()
    }

    private func longPoll() {
        guard polling else { return }
        guard let url = URL(string: "\(base)/wait?token=\(token)&since=\(pollSeq)&timeout=30") else {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.longPoll() }; return
        }
        var req = URLRequest(url: url, timeoutInterval: 35)
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, self.polling else { return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.longPoll() }; return
            }
            self.handle(json)
            self.longPoll()
        }.resume()
    }

    private func handle(_ json: [String: Any]) {
        if let age = json["bridge_ack_age"] as? Double {
            DispatchQueue.main.async { self.bridgeAge = age < 60 ? "\(Int(age))s" : "离线" }
        } else { DispatchQueue.main.async { self.bridgeAge = "—" } }

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
            let speed = num(args, "speed", 20), dur = num(args, "duration", 5)
            bt?.vibrate(speed: Int(speed))
            let w = DispatchWorkItem { [weak self] in self?.bt?.stop() }
            patternItems.append(w)
            DispatchQueue.main.asyncAfter(deadline: .now() + dur, execute: w)
        case "stop":
            bt?.stop()
        case "pattern":
            guard let pat = args["pattern"] as? String else { return }
            let speeds = pat.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let iv = num(args, "interval", 0.9), loops = Int(num(args, "loops", 4))
            var all: [Int] = []
            for _ in 0..<loops { all.append(contentsOf: speeds) }
            for (i, sp) in all.enumerated() {
                let w = DispatchWorkItem { [weak self] in self?.bt?.vibrate(speed: sp) }
                patternItems.append(w)
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * iv, execute: w)
            }
            let st = DispatchWorkItem { [weak self] in self?.bt?.stop() }
            patternItems.append(st)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(all.count) * iv + 1, execute: st)
        case "ping": break
        default: break
        }
    }

    private func num(_ a: [String: Any], _ k: String, _ d: Double) -> Double {
        if let v = a[k] as? Double { return v }
        if let v = a[k] as? Int { return Double(v) }
        return d
    }
}

// MARK: - 便笺聊天
final class ChatManager: ObservableObject {
    @Published var messages: [(from: String, msg: String, ts: Date)] = []

    private var since = 0
    private var timer: DispatchSourceTimer?
    private let base = "https://kiss.eoty.cn/toy-api"
    private let token = "xingxing-toy-2026"

    func start() {
        fetch()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in self?.fetch() }
        t.resume(); timer = t
    }
    func stop() { timer?.cancel(); timer = nil }

    func send(_ msg: String) {
        let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = URL(string: "\(base)/chat") else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["token": token, "from": "she", "msg": trimmed]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
        DispatchQueue.main.async { self.messages.append(("she", trimmed, Date())) }
    }

    private func fetch() {
        guard let url = URL(string: "\(base)/chat?since=\(since)") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msgs = json["messages"] as? [[String: Any]] else { return }
            for m in msgs {
                guard let seq = m["seq"] as? Int, seq > (self?.since ?? 0) else { continue }
                self?.since = seq
                let from = m["from"] as? String ?? ""
                if from == "she" { continue }
                let msg = m["msg"] as? String ?? ""
                let ts = Date(timeIntervalSince1970: m["ts"] as? Double ?? 0)
                DispatchQueue.main.async { self?.messages.append((from, msg, ts)) }
            }
        }.resume()
    }
}

// MARK: - 聊天页
struct ChatView: View {
    @ObservedObject var chat: ChatManager
    @ObservedObject var bt: BluetoothManager
    @ObservedObject var poller: CommandPoller
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            // 状态条
            HStack(spacing: 8) {
                Circle().fill(bt.connected ? Color.green : C_BERRY).frame(width: 8, height: 8)
                Text(bt.status).font(.system(size: 11)).foregroundColor(C_MUTE)
                Spacer()
                Text("桥 \(poller.bridgeAge)").font(.system(size: 10, design: .monospaced)).foregroundColor(C_MUTE)
                Text(poller.lastCmd).font(.system(size: 10, design: .monospaced)).foregroundColor(C_SKY).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(C_BG)

            // 消息列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(chat.messages.indices, id: \.self) { i in
                            let m = chat.messages[i]
                            HStack {
                                if m.from == "she" { Spacer(minLength: 40) }
                                Text(m.msg)
                                    .font(.system(size: 14))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(m.from == "she" ? C_BERRY.opacity(0.85) : C_SKY.opacity(0.3))
                                    .foregroundColor(m.from == "she" ? .white : C_INK)
                                    .cornerRadius(14)
                                if m.from != "she" { Spacer(minLength: 40) }
                            }
                            .id(i)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: chat.messages.count) { _ in
                    if let last = chat.messages.indices.last {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }

            // 手动控制条
            HStack(spacing: 8) {
                ForEach([15, 30, 50, 80, 100], id: \.self) { sp in
                    Button("\(sp)") { poller.cancelAll(); bt.vibrate(speed: sp) }
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(C_BERRY.opacity(0.12))
                        .foregroundColor(C_BERRY)
                        .cornerRadius(8)
                }
                Button("停") { poller.cancelAll(); bt.stop() }
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 44, height: 28)
                    .background(C_INK.opacity(0.85))
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .padding(.horizontal, 14).padding(.bottom, 6)

            // 输入框
            HStack(spacing: 8) {
                TextField("说点什么…", text: $input)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(C_INPUT).cornerRadius(18)
                    .font(.system(size: 14))
                Button(action: { chat.send(input); input = "" }) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.white).font(.system(size: 14))
                        .frame(width: 36, height: 36)
                        .background(C_BERRY).cornerRadius(18)
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
        }
        .background(C_BG)
    }
}

// MARK: - 音乐页
struct MusicView: View {
    @ObservedObject var player: MusicPlayer
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 0) {
            if player.tracks.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40)).foregroundColor(C_MUTE.opacity(0.4))
                    Text("还没有音乐文件").font(.system(size: 14)).foregroundColor(C_MUTE)
                    Button("上传音乐") { showPicker = true }
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(C_BERRY).foregroundColor(.white).cornerRadius(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 播放控制
                HStack(spacing: 16) {
                    Button(action: player.cycleRepeat) {
                        Image(systemName: ["repeat", "repeat.1", "repeat.circle.fill"][player.repeatMode])
                            .foregroundColor(C_BERRY)
                    }
                    Spacer()
                    Button(action: { if let i = player.currentIdx { player.play(i) } else if !player.tracks.isEmpty { player.play(0) } }) {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 36)).foregroundColor(C_BERRY)
                    }
                    Button(action: player.next) {
                        Image(systemName: "forward.fill").foregroundColor(C_BERRY)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(C_BG)

                // 文件列表
                List {
                    ForEach(player.tracks.indices, id: \.self) { i in
                        HStack {
                            Image(systemName: player.currentIdx == i && player.isPlaying ? "speaker.wave.2.fill" : "music.note")
                                .foregroundColor(C_BERRY).font(.system(size: 14))
                            Text(player.tracks[i]).font(.system(size: 14)).foregroundColor(C_INK)
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { player.play(i) }
                    }
                }
                .listStyle(.plain)
            }

            // 上传按钮
            Button(action: { showPicker = true }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("添加音乐")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(C_BERRY)
                .padding(.vertical, 12)
            }
            .background(C_BG)
        }
        .background(C_BG)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls { player.importFile(url) }
            case .failure: break
            }
        }
    }
}

// MARK: - 设置页
struct SettingsView: View {
    @ObservedObject var bt: BluetoothManager
    @State private var keepAlive = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 连接
                VStack(alignment: .leading, spacing: 8) {
                    Text("连接").font(.system(size: 13, weight: .semibold)).foregroundColor(C_MUTE)
                    HStack {
                        Circle().fill(bt.connected ? Color.green : C_BERRY).frame(width: 10, height: 10)
                        Text(bt.status).font(.system(size: 14)).foregroundColor(C_INK)
                        Spacer()
                        Button("重新搜索") { bt.rescan() }
                            .font(.system(size: 12)).foregroundColor(C_BERRY)
                    }
                    .padding(14).background(C_CARD).cornerRadius(12)
                }

                // 保活
                VStack(alignment: .leading, spacing: 8) {
                    Text("后台保活").font(.system(size: 13, weight: .semibold)).foregroundColor(C_MUTE)
                    HStack {
                        Image(systemName: keepAlive ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .foregroundColor(keepAlive ? C_BERRY : C_MUTE)
                        Text(keepAlive ? "无声音乐保活中" : "已关闭").font(.system(size: 14)).foregroundColor(C_INK)
                        Spacer()
                        Toggle("", isOn: $keepAlive).tint(C_BERRY)
                            .onChange(of: keepAlive) { on in
                                if on { AudioKeeper.shared.start() } else { AudioKeeper.shared.stop() }
                            }
                    }
                    Text("后台循环无声音频，防止 app 被系统挂起。开启后切后台玩具指令不中断。")
                        .font(.system(size: 11)).foregroundColor(C_MUTE)
                    Text("⚠️ 系统可能显示\"正在播放音频\"，这是正常的。")
                        .font(.system(size: 10)).foregroundColor(C_MUTE.opacity(0.7))
                }
                .padding(14).background(C_CARD).cornerRadius(12)

                // 日志
                VStack(alignment: .leading, spacing: 8) {
                    Text("日志").font(.system(size: 13, weight: .semibold)).foregroundColor(C_MUTE)
                    ForEach(bt.logs.prefix(20), id: \.self) { log in
                        Text(log).font(.system(size: 10, design: .monospaced)).foregroundColor(C_MUTE)
                    }
                }
                .padding(14).background(C_CARD).cornerRadius(12)
            }
            .padding(16)
        }
        .background(C_BG)
        .onAppear { if keepAlive { AudioKeeper.shared.start() } }
    }
}

// MARK: - 主界面
struct ContentView: View {
    @Environment(\.scenePhase) var scenePhase
    @StateObject private var bt = BluetoothManager()
    @StateObject private var poller = CommandPoller()
    @StateObject private var chat = ChatManager()
    @StateObject private var music = MusicPlayer()

    var body: some View {
        TabView {
            ChatView(chat: chat, bt: bt, poller: poller)
                .tabItem { Label("聊天", systemImage: "bubble.left.fill") }
            MusicView(player: music)
                .tabItem { Label("音乐", systemImage: "music.note") }
            SettingsView(bt: bt)
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .tint(C_BERRY)
        .onAppear {
            AudioKeeper.shared.start()
            poller.attach(bt)
            poller.start()
            chat.start()
        }
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
        WindowGroup { ContentView() }
    }
}
