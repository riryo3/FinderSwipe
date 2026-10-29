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
}

// MARK: - 判定エンジン

final class Engine {
    static let shared = Engine()
    var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    var remoteMode = UserDefaults.standard.bool(forKey: "remoteMode")
    var ucMode = UserDefaults.standard.bool(forKey: "ucMode")
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
        // ユニバーサルコントロール用モードでは最前面を問わない
        // (カーソルが相手側の画面にあるとき、キーはそちらに届く。手元側の Finder でも同じ意味になる)
        var note = ""
        if !enabled {
            note = "（無効中）"
        } else if isFinder || isRemote || ucMode {
            switch action {
            case .back: sendKey(33)      // [
            case .forward: sendKey(30)   // ]
            case .parent: sendKey(126)   // ↑
            case .open: sendKey(31)      // O
            }
        } else {
            note = "（対象のアプリ以外のため送信なし）"
        }
        let label = action.rawValue + note
        DispatchQueue.main.async { [weak self] in self?.onAction?(label) }
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
    var ucItem: NSMenuItem!
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
        ucItem = NSMenuItem(title: "ユニバーサルコントロール用（最前面を問わず送る）", action: #selector(toggleUC), keyEquivalent: "")
        ucItem.target = self
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
        menu.addItem(enabledItem); menu.addItem(remoteItem); menu.addItem(ucItem); menu.addItem(tapItem); menu.addItem(lastItem); menu.addItem(mtItem); menu.addItem(statsItem); menu.addItem(.separator())
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
        ucItem.state = Engine.shared.ucMode ? .on : .off
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

    @objc func toggleUC() {
        Engine.shared.ucMode.toggle()
        UserDefaults.standard.set(Engine.shared.ucMode, forKey: "ucMode")
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
