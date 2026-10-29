import Cocoa
import ApplicationServices

// FinderSwipe: Finder でスワイプ操作するための常駐アプリ(試作)
// - 2本指の横フリック → 戻る(⌘[) / 進む(⌘])
// - 3本指の下スワイプ → 上の階層(⌘↑)、3本指の上スワイプ → 開く(⌘O)
// Finder が最前面のときだけ効く。指の動きは MultitouchSupport(Private)で直接読む。

// MARK: - MultitouchSupport の型(コミュニティで知られている定義)

struct MTPoint { var x: Float; var y: Float }
struct MTReadout { var position: MTPoint; var velocity: MTPoint }
struct Finger {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32          // 3 = 触れた, 4 = 触れている
    var finger: Int32
    var hand: Int32
    var normalized: MTReadout // 位置は 0...1 に正規化(y は上が +)
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTReadout
    var zero2: Int32
    var zero3: Int32
    var density: Float
}

typealias MTContactCallback = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void

func mtCallback(_ device: Int32, _ fingers: UnsafeMutableRawPointer?, _ count: Int32, _ timestamp: Double, _ frame: Int32) {
    Engine.shared.noteFrame(rawCount: Int(count), timestamp: timestamp)
    guard let fingers = fingers, count > 0 else {
        Engine.shared.handle([], timestamp: timestamp)
        return
    }
    let typed = fingers.assumingMemoryBound(to: Finger.self)
    Engine.shared.handle(Array(UnsafeBufferPointer(start: typed, count: Int(count))), timestamp: timestamp)
}

enum SwipeAction: String {
    case back = "戻る"
    case forward = "進む"
    case parent = "上の階層へ"
    case open = "開く"

    /// 相方連携で送る合図の名前
    var wire: String {
        switch self {
        case .back: return "back"
        case .forward: return "forward"
        case .parent: return "parent"
        case .open: return "open"
        }
    }

    static func fromWire(_ wire: String) -> SwipeAction? {
        switch wire {
        case "back": return .back
        case "forward": return .forward
        case "parent": return .parent
        case "open": return .open
        default: return nil
        }
    }
}

// MARK: - 判定エンジン

final class Engine {
    static let shared = Engine()
    var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    var remoteMode = UserDefaults.standard.bool(forKey: "remoteMode")
    var linkMode = UserDefaults.standard.bool(forKey: "linkMode")
    var keyTapSession = UserDefaults.standard.bool(forKey: "keyTapSession")
    var onAction: ((String) -> Void)?
    var onStats: ((Int, Int) -> Void)?

    // 診断用: コールバックが来ているか、指の数が読めているか
    private(set) var frames = 0
    private(set) var maxFingers = 0
    private var lastStatsPush: Double = 0

    func noteFrame(rawCount: Int, timestamp: Double) {
        frames += 1
        if rawCount > maxFingers { maxFingers = rawCount }
        if timestamp - lastStatsPush > 0.25 {
            lastStatsPush = timestamp
            let f = frames, m = maxFingers
            DispatchQueue.main.async { [weak self] in self?.onStats?(f, m) }
        }
    }

    private var session = false
    private var lockedCount = 0       // セッション中に確認した最大の指の数(2 か 3)
    private var startX: Float = 0, startY: Float = 0
    private var startT: Double = 0
    private var fired = false

    // しきい値(正規化座標 0...1 に対する割合)
    private let flickMin: Float = 0.20     // 2本指フリックの最小移動量
    private let vertMin: Float = 0.20      // 3本指の最小移動量
    private let flickMaxTime = 0.6         // 2本指はこの時間内に大きく動いたものだけ拾う
    private let graceTime = 0.09           // 3本目が遅れて触れるのを待つ時間

    func handle(_ fingers: [Finger], timestamp: Double) {
        let downs = fingers.filter { $0.state == 3 || $0.state == 4 }
        if downs.isEmpty { session = false; fired = false; lockedCount = 0; return }
        let n = downs.count
        let cx = downs.reduce(Float(0)) { $0 + $1.normalized.position.x } / Float(n)
        let cy = downs.reduce(Float(0)) { $0 + $1.normalized.position.y } / Float(n)

        if !session {
            guard n >= 2 else { return }
            session = true; lockedCount = n
            startX = cx; startY = cy; startT = timestamp; fired = false
            return
        }
        if n > lockedCount { lockedCount = n }
        guard !fired, n >= 2 else { return }
        let dx = cx - startX, dy = cy - startY
        let elapsed = timestamp - startT

        if lockedCount == 2 {
            // 横フリック: 右へ = 戻る、左へ = 進む(Safari と同じ向き)
            guard elapsed >= graceTime, elapsed <= flickMaxTime else { return }
            if abs(dx) >= flickMin, abs(dx) >= 2 * abs(dy) {
                fire(dx > 0 ? .back : .forward)
            }
        } else if lockedCount == 3 {
            // 縦: 下へ = 上の階層、上へ = 開く
            if abs(dy) >= vertMin, abs(dy) >= 2 * abs(dx) {
                fire(dy > 0 ? .open : .parent)
            }
        }
    }

    private func fire(_ action: SwipeAction) {
        fired = true
        // 送ってよい場面: Finder が最前面のとき。
        // リモート操作モードでは Moonlight が最前面のときも送る(キーは Moonlight 経由で相手側に届く)
        let front = NSWorkspace.shared.frontmostApplication
        let isFinder = front?.bundleIdentifier == "com.apple.finder"
        let isRemote = remoteMode && front?.localizedName == "Moonlight"
        var note = ""
        if !enabled {
            note = "（無効中）"
        } else if isFinder || isRemote {
            postKey(for: action)
        } else if linkMode {
            // ユニバーサルコントロールは合成キーを相手側へ転送しないので、
            // 手元で処理されなかったスワイプは「合図」として相方に送る
            LinkNet.send(action.wire)
            note = "（合図を送信）"
        } else {
            note = "（対象のアプリ以外のため送信なし）"
        }
        let label = action.rawValue + note
        DispatchQueue.main.async { [weak self] in self?.onAction?(label) }
    }

    /// 相方から合図が届いたとき。自分の Finder が最前面のときだけ実行する
    func receiveLink(_ wire: String) {
        guard enabled, linkMode else { return }
        guard let action = SwipeAction.fromWire(wire) else { return }
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier == "com.apple.finder" else { return }
        postKey(for: action)
        let label = "合図を受信： \(action.rawValue)"
        DispatchQueue.main.async { [weak self] in self?.onAction?(label) }
    }

    private func postKey(for action: SwipeAction) {
        switch action {
        case .back: sendKey(33)      // [
        case .forward: sendKey(30)   // ]
        case .parent: sendKey(126)   // ↑
        case .open: sendKey(31)      // O
        }
    }

    private func sendKey(_ keyCode: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        // ユニバーサルコントロールが拾う経路を探るため、送信方式を切り替えられるようにしている
        let tap: CGEventTapLocation = keyTapSession ? .cgSessionEventTap : .cghidEventTap
        for down in [true, false] {
            if let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) {
                e.flags = .maskCommand
                e.post(tap: tap)
            }
        }
    }
}

// MARK: - 相方連携(同じネットワーク内で合図を送り合う)

// ユニバーサルコントロールは「本物のキーボード入力」しか相手側へ転送せず、
// アプリが合成したキーはどちらの送信方式でも届かなかった(実機で確認済み)。
// そこで、スワイプの「合図」だけを UDP ブロードキャストで送り、
// 受け側の FinderSwipe が自分の Finder にキーを送る形にする。
// 注意: 同じ LAN 内なら誰でも合図を送れてしまう試作仕様(家庭内利用前提)。
enum LinkNet {
    static let port: UInt16 = 45987
    private static let magic = "FSWIPE1 "
    private static var seenSeqs: [UInt64: Double] = [:]

    static func send(_ wire: String) {
        let seq = UInt64(Date().timeIntervalSince1970 * 1000)
        let payload = Array((magic + "\(seq) " + wire).utf8)
        DispatchQueue.global().async {
            for _ in 0..<3 {  // UDP の取りこぼし対策に、同じ合図を3回送る
                let fd = socket(AF_INET, SOCK_DGRAM, 0)
                guard fd >= 0 else { return }
                var yes: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr.s_addr = INADDR_BROADCAST
                payload.withUnsafeBytes { buf in
                    withUnsafePointer(to: &addr) { p in
                        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            _ = sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                close(fd)
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
    }

    static func startReceiver() {
        DispatchQueue.global().async {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let bound = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { return }
            var buf = [UInt8](repeating: 0, count: 256)
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                guard n > 0 else { continue }
                let s = String(decoding: buf[0..<n], as: UTF8.self)
                guard s.hasPrefix(magic) else { continue }
                let parts = s.dropFirst(magic.count).split(separator: " ")
                guard parts.count == 2, let seq = UInt64(parts[0]) else { continue }
                // 3回送られてくる同じ合図は1回だけ実行する
                let now = Date().timeIntervalSince1970
                if let seen = seenSeqs[seq], now - seen < 2 { continue }
                seenSeqs[seq] = now
                seenSeqs = seenSeqs.filter { now - $0.value < 10 }
                Engine.shared.receiveLink(String(parts[1]))
            }
        }
    }
}

// MARK: - MultitouchSupport の読み込み

final class Multitouch {
    typealias CreateListFn = @convention(c) () -> UnsafeMutableRawPointer?
    typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer?, MTContactCallback) -> Void
    typealias StartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private static var retainedList: CFMutableArray?

    /// 接続できたデバイス数を返す(0 = 失敗)
    static func start() -> Int {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let createSym = dlsym(handle, "MTDeviceCreateList"),
              let regSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let listPtr = unsafeBitCast(createSym, to: CreateListFn.self)() else { return 0 }
        let register = unsafeBitCast(regSym, to: RegisterFn.self)
        let start = unsafeBitCast(startSym, to: StartFn.self)
        let list = Unmanaged<CFMutableArray>.fromOpaque(listPtr).takeRetainedValue()
        retainedList = list
        let n = CFArrayGetCount(list)
        guard n > 0 else { return 0 }
        for i in 0..<n {
            let dev = CFArrayGetValueAtIndex(list, i)
            register(UnsafeMutableRawPointer(mutating: dev), mtCallback)
            start(UnsafeMutableRawPointer(mutating: dev), 0)
        }
        return n
    }
}

// MARK: - アプリ本体

/// メニューバー用の「指3本」アイコン(テンプレート画像)
func fingerIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        NSColor.black.setFill()
        let specs: [(CGFloat, CGFloat)] = [(2.5, 9), (7.5, 12), (12.5, 10)]  // (x, 高さ)。中指がいちばん高い
        for (x, h) in specs {
            NSBezierPath(roundedRect: NSRect(x: x, y: 3, width: 3.2, height: h), xRadius: 1.6, yRadius: 1.6).fill()
        }
        return true
    }
    img.isTemplate = true
    return img
}

final class App: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var enabledItem: NSMenuItem!
    var remoteItem: NSMenuItem!
    var linkItem: NSMenuItem!
    var tapItem: NSMenuItem!
    var lastItem: NSMenuItem!
    var mtItem: NSMenuItem!
    var statsItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = fingerIcon()
        let menu = NSMenu()
        enabledItem = NSMenuItem(title: "有効", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        remoteItem = NSMenuItem(title: "リモート操作モード（Moonlight 使用時も有効）", action: #selector(toggleRemote), keyEquivalent: "")
        remoteItem.target = self
        linkItem = NSMenuItem(title: "相方モード（ネットワークで合図を送受信）", action: #selector(toggleLink), keyEquivalent: "")
        linkItem.target = self
        tapItem = NSMenuItem(title: "キー送信をセッション方式にする", action: #selector(toggleTap), keyEquivalent: "")
        tapItem.target = self
        lastItem = NSMenuItem(title: "最後の検出： なし", action: nil, keyEquivalent: "")
        lastItem.isEnabled = false
        mtItem = NSMenuItem(title: "トラックパッド： —", action: nil, keyEquivalent: "")
        mtItem.isEnabled = false
        statsItem = NSMenuItem(title: "受信： 0フレーム / 最大0本", action: nil, keyEquivalent: "")
        statsItem.isEnabled = false
        let permItem = NSMenuItem(title: "アクセシビリティ許可を開く…", action: #selector(openPermSettings), keyEquivalent: "")
        permItem.target = self
        menu.addItem(enabledItem); menu.addItem(remoteItem); menu.addItem(linkItem); menu.addItem(tapItem); menu.addItem(lastItem); menu.addItem(mtItem); menu.addItem(statsItem); menu.addItem(.separator())
        menu.addItem(permItem); menu.addItem(.separator())
        menu.addItem(withTitle: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        refreshMenu()

        Engine.shared.onAction = { [weak self] label in
            self?.flashIcon()
            self?.lastItem.title = "最後の検出： \(label)"
        }
        Engine.shared.onStats = { [weak self] frames, maxFingers in
            self?.statsItem.title = "受信： \(frames)フレーム / 最大\(maxFingers)本"
        }

        // キーを送るにはアクセシビリティ許可が要る
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            alert("アクセシビリティ許可が必要です",
                  "スワイプで Finder にキーを送るため、システム設定 → プライバシーとセキュリティ → アクセシビリティ で FinderSwipe を許可してください。許可したら FinderSwipe を再起動してください。")
        }

        LinkNet.startReceiver()

        let devices = Multitouch.start()
        mtItem.title = devices > 0 ? "トラックパッド： 接続OK（\(devices)台）" : "トラックパッド： 接続失敗"
        if devices == 0 {
            alert("トラックパッドを読み込めませんでした",
                  "MultitouchSupport を開くか、トラックパッドの検出に失敗しました。この Mac では試作方式が使えない可能性があります。")
        }
    }

    func refreshMenu() {
        enabledItem.state = Engine.shared.enabled ? .on : .off
        remoteItem.state = Engine.shared.remoteMode ? .on : .off
        linkItem.state = Engine.shared.linkMode ? .on : .off
        tapItem.state = Engine.shared.keyTapSession ? .on : .off
    }

    var flashRestore: DispatchWorkItem?

    /// 検知した瞬間に、メニューバーのアイコンを一瞬薄くして知らせる
    func flashIcon() {
        guard let button = item.button else { return }
        flashRestore?.cancel()
        button.alphaValue = 0.25
        let work = DispatchWorkItem { [weak self] in self?.item.button?.alphaValue = 1.0 }
        flashRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    @objc func toggleEnabled() {
        Engine.shared.enabled.toggle()
        UserDefaults.standard.set(Engine.shared.enabled, forKey: "enabled")
        refreshMenu()
    }

    @objc func toggleRemote() {
        Engine.shared.remoteMode.toggle()
        UserDefaults.standard.set(Engine.shared.remoteMode, forKey: "remoteMode")
        refreshMenu()
    }

    @objc func toggleLink() {
        Engine.shared.linkMode.toggle()
        UserDefaults.standard.set(Engine.shared.linkMode, forKey: "linkMode")
        refreshMenu()
    }

    @objc func toggleTap() {
        Engine.shared.keyTapSession.toggle()
        UserDefaults.standard.set(Engine.shared.keyTapSession, forKey: "keyTapSession")
        refreshMenu()
    }

    @objc func openPermSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let d = App(); app.delegate = d
app.run()
