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
        } else if isFinder {
            postKey(for: action)
        } else if linkMode {
            // ユニバーサルコントロールは合成キーを相手側へ転送しないので、
            // 手元で処理されなかったスワイプは「合図」として相方に送る。
            // Moonlight のときも、相方モードがオンならキー直送より合図を優先する
            // (Windows など、受け側でキー変換が必要な相手にも同じ合図で届くため)
            LinkNet.send(action.wire)
            note = "（合図を送信）"
        } else if isRemote {
            postKey(for: action)
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
    private static var fastSeq: UInt64 = 0

    /// 自分の識別子(自分の送った合図を自分で受けないため)
    static let machineID: String = {
        if let s = UserDefaults.standard.string(forKey: "machineID") { return s }
        let s = String(UInt32.random(in: 0..<UInt32.max), radix: 16)
        UserDefaults.standard.set(s, forKey: "machineID")
        return s
    }()

    private static func udpSend(_ text: String) {
        let payload = Array(text.utf8)
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
    }

    /// スワイプの合図(確実に届けたいので同じものを3回送る)
    static func send(_ wire: String) {
        let seq = UInt64(Date().timeIntervalSince1970 * 1000)
        let text = magic + "\(machineID) \(seq) \(wire)"
        DispatchQueue.global().async {
            for _ in 0..<3 {
                udpSend(text)
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
    }

    /// カーソル共有の細かい合図(速さ優先で1回だけ送る)
    static func sendFast(_ body: String) {
        fastSeq &+= 1
        udpSend(magic + "\(machineID) \(fastSeq) \(body)")
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
                guard parts.count >= 3, String(parts[0]) != machineID, let seq = UInt64(parts[1]) else { continue }
                let kind = String(parts[2])
                if SwipeAction.fromWire(kind) != nil {
                    // スワイプの合図: 3回送られてくる同じものは1回だけ実行する
                    let now = Date().timeIntervalSince1970
                    if let seen = seenSeqs[seq], now - seen < 2 { continue }
                    seenSeqs[seq] = now
                    seenSeqs = seenSeqs.filter { now - $0.value < 10 }
                    Engine.shared.receiveLink(kind)
                } else {
                    // カーソル共有の合図
                    CursorShare.shared.receive(kind, args: parts.dropFirst(3).map { String($0) })
                }
            }
        }
    }
}

// MARK: - カーソル共有(試作)

func cursorTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    CursorShare.shared.handle(type: type, event: event)
}

/// カーソル共有の試作。右端にカーソルが触れたら操作を相方に渡す。
/// 送り側はイベントタップでマウスとキーを横取りして合図に変換し、
/// 受け側は合図から合成イベントを作って自分の画面で再現する。
/// 受け側でカーソルが左端を越えたら手元に返る。送信中に Esc を押しても返る(非常口)。
final class CursorShare {
    static let shared = CursorShare()
    var enabled = UserDefaults.standard.bool(forKey: "cursorShare")
    var onStatus: ((String) -> Void)?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private(set) var sending = false
    private(set) var receiving = false
    private var vx: Double = 0, vy: Double = 0

    private var mainBounds: CGRect { CGDisplayBounds(CGMainDisplayID()) }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "cursorShare")
        if on {
            installTap()
        } else {
            endSending(notify: true)
            receiving = false
            removeTap()
        }
    }

    func installTap() {
        guard tap == nil else { return }
        var mask: CGEventMask = 0
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        for t in types { mask |= (CGEventMask(1) << CGEventMask(t.rawValue)) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: cursorTapCallback, userInfo: nil) else {
            status("カーソル共有： タップを作れませんでした（許可を確認してください）")
            return
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func removeTap() {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let src = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil
        tapSource = nil
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard enabled, !receiving else { return Unmanaged.passUnretained(event) }
        if !sending {
            // 右端に触れたら開始する
            if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
                let b = mainBounds
                let loc = event.location
                if loc.x >= b.maxX - 1 {
                    beginSending(yRatio: Double((loc.y - b.minY) / b.height))
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }
        // 送信中: Esc は非常口(合図にせず、その場で手元に戻す)
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
            endSending(notify: true)
            return nil
        }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = event.getIntegerValueField(.mouseEventDeltaX)
            let dy = event.getIntegerValueField(.mouseEventDeltaY)
            if dx != 0 || dy != 0 { LinkNet.sendFast("mv \(dx) \(dy)") }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            LinkNet.sendFast("dn \(event.getIntegerValueField(.mouseEventButtonNumber))")
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            LinkNet.sendFast("up \(event.getIntegerValueField(.mouseEventButtonNumber))")
        case .scrollWheel:
            let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            if dx != 0 || dy != 0 { LinkNet.sendFast("sc \(Int(dy)) \(Int(dx))") }
        case .keyDown:
            LinkNet.sendFast("kd \(event.getIntegerValueField(.keyboardEventKeycode)) \(event.flags.rawValue)")
        case .keyUp:
            LinkNet.sendFast("ku \(event.getIntegerValueField(.keyboardEventKeycode)) \(event.flags.rawValue)")
        case .flagsChanged:
            LinkNet.sendFast("fl \(event.getIntegerValueField(.keyboardEventKeycode)) \(event.flags.rawValue)")
        default:
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    private func beginSending(yRatio: Double) {
        sending = true
        for _ in 0..<3 { LinkNet.sendFast("enter \(yRatio)") }  // 大事な合図なので3回送る
        status("カーソル共有： 相手に渡しました")
    }

    func endSending(notify: Bool) {
        guard sending else { return }
        sending = false
        if notify { LinkNet.sendFast("leave") }
        status("カーソル共有： 手元に戻りました")
    }

    /// 受け側: LinkNet から呼ばれる
    func receive(_ kind: String, args: [String]) {
        guard enabled else { return }
        let b = mainBounds
        switch kind {
        case "enter":
            guard !sending else { return }
            receiving = true
            vx = Double(b.minX)
            let ratio = args.first.flatMap { Double($0) } ?? 0.5
            vy = Double(b.minY) + ratio * Double(b.height)
            warp()
            status("カーソル共有： 相手から受け取りました")
        case "leave":
            if receiving { receiving = false; status("カーソル共有： 相手に戻りました") }
            if sending { endSending(notify: false) }
        case "mv":
            guard receiving, args.count == 2, let dx = Double(args[0]), let dy = Double(args[1]) else { return }
            vx += dx
            vy += dy
            vy = min(max(vy, Double(b.minY)), Double(b.maxY) - 1)
            if vx < Double(b.minX) {
                receiving = false
                LinkNet.sendFast("leave")
                status("カーソル共有： 手元に返しました")
                return
            }
            vx = min(vx, Double(b.maxX) - 1)
            warp()
        case "dn", "up":
            guard receiving, let n = args.first.flatMap({ Int($0) }) else { return }
            postMouse(down: kind == "dn", button: n)
        case "sc":
            guard receiving, args.count == 2, let dy = Int32(args[0]), let dx = Int32(args[1]) else { return }
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
                e.location = CGPoint(x: vx, y: vy)
                e.post(tap: .cghidEventTap)
            }
        case "kd", "ku", "fl":
            guard receiving, args.count == 2, let code = UInt16(args[0]), let flagsRaw = UInt64(args[1]) else { return }
            if let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: kind != "ku") {
                e.flags = CGEventFlags(rawValue: flagsRaw)
                if kind == "fl" { e.type = .flagsChanged }
                e.post(tap: .cghidEventTap)
            }
        default:
            break
        }
    }

    private func warp() {
        CGWarpMouseCursorPosition(CGPoint(x: vx, y: vy))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func postMouse(down: Bool, button: Int) {
        let downType: CGEventType, upType: CGEventType, btn: CGMouseButton
        switch button {
        case 1: downType = .rightMouseDown; upType = .rightMouseUp; btn = .right
        case 2: downType = .otherMouseDown; upType = .otherMouseUp; btn = .center
        default: downType = .leftMouseDown; upType = .leftMouseUp; btn = .left
        }
        if let e = CGEvent(mouseEventSource: nil, mouseType: down ? downType : upType,
                           mouseCursorPosition: CGPoint(x: vx, y: vy), mouseButton: btn) {
            e.post(tap: .cghidEventTap)
        }
    }

    private func status(_ s: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(s) }
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
    var cursorItem: NSMenuItem!
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
        cursorItem = NSMenuItem(title: "カーソル共有（右端で相手に渡す）", action: #selector(toggleCursor), keyEquivalent: "")
        cursorItem.target = self
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
        menu.addItem(enabledItem); menu.addItem(remoteItem); menu.addItem(linkItem); menu.addItem(cursorItem); menu.addItem(tapItem); menu.addItem(lastItem); menu.addItem(mtItem); menu.addItem(statsItem); menu.addItem(.separator())
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
        CursorShare.shared.onStatus = { [weak self] label in
            self?.flashIcon()
            self?.lastItem.title = "最後の検出： \(label)"
        }
        if CursorShare.shared.enabled { CursorShare.shared.installTap() }

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
        cursorItem.state = CursorShare.shared.enabled ? .on : .off
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

    @objc func toggleCursor() {
        CursorShare.shared.setEnabled(!CursorShare.shared.enabled)
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
