import Cocoa
import SwiftTerm

// 常に最前面に表示できるターミナル。
// 中身は SwiftTerm の LocalProcessTerminalView で、ログインシェル（zsh）をそのまま動かす。

private let floatingKey = "floatingEnabled"
private let transparencyKey = "transparencyLevel"

final class AppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    private var window: NSWindow!
    private var terminalView: LocalProcessTerminalView!
    private var floatingItem: NSMenuItem!
    private var statusBar: NSView!
    private var statusLabel: NSTextField!

    private var isFloating: Bool {
        get { UserDefaults.standard.object(forKey: floatingKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: floatingKey) }
    }

    // 透過の段階。0 = 透過0%（背景も完全に不透明）、1 = ターミナル.app のプロファイルどおり、
    // 2〜8 = ウインドウ全体を 10%〜70% 透過
    private var transparencyLevel: Int {
        get { UserDefaults.standard.object(forKey: transparencyKey) as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: transparencyKey) }
    }
    private let maxTransparencyLevel = 8

    // プロファイルから読んだ背景色とぼかし（透過0%から戻すときに使う）
    private var profileBackground: NSColor = .black
    private var profileBlur: Int32 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        startShell()
        applyFloating()
        applyTransparency()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - ウインドウ

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Floating Terminal"
        // フルスクリーンのアプリの上にも重ねられるようにする
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.center()
        window.setFrameAutosaveName("FloatingTerminalMainWindow")

        let container = NSView(frame: window.contentView!.bounds)
        container.autoresizingMask = [.width, .height]

        let barHeight: CGFloat = 22
        var termFrame = container.bounds
        termFrame.origin.y = barHeight
        termFrame.size.height -= barHeight
        terminalView = LocalProcessTerminalView(frame: termFrame)
        terminalView.autoresizingMask = [.width, .height]
        terminalView.processDelegate = self
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        container.addSubview(terminalView)

        statusBar = NSView(frame: NSRect(x: 0, y: 0, width: container.bounds.width, height: barHeight))
        statusBar.autoresizingMask = [.width]
        statusBar.wantsLayer = true
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.frame = NSRect(x: 8, y: 3, width: container.bounds.width - 16, height: 16)
        statusLabel.autoresizingMask = [.width]
        statusBar.addSubview(statusLabel)
        container.addSubview(statusBar)

        window.contentView = container
        applyTerminalAppProfile()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminalView)
    }

    private func startShell() {
        let env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let home = env["HOME"] ?? NSHomeDirectory()

        var vars = [
            "TERM=xterm-256color",
            "COLORTERM=truecolor",
            "LANG=ja_JP.UTF-8",
            "TERM_PROGRAM=FloatingTerminal",
            "HOME=\(home)",
            "SHELL=\(shell)",
            "PATH=\(env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")",
        ]
        for key in ["USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK"] {
            if let value = env[key] { vars.append("\(key)=\(value)") }
        }

        // 先頭に "-" を付けた名前で起動するとログインシェルになり、.zprofile なども読まれる
        let execName = "-" + (shell as NSString).lastPathComponent
        terminalView.startProcess(executable: shell, args: [], environment: vars,
                                  execName: execName, currentDirectory: home)
    }

    private func applyFloating() {
        window.level = isFloating ? .floating : .normal
        floatingItem.state = isFloating ? .on : .off
        updateStatus()
    }

    private func updateStatus() {
        let floating = isFloating
            ? "📌 常に手前に表示：ON（⌘⇧T でOFF）"
            : "常に手前に表示：OFF（⌘⇧T でON）"
        let transparency: String
        switch transparencyLevel {
        case 0: transparency = "0%"
        case 1: transparency = "ターミナルと同じ"
        default: transparency = "\((transparencyLevel - 1) * 10)%"
        }
        statusLabel.stringValue = "\(floating)　　透過：\(transparency)（⌘- / ⌘=）"
    }

    // ターミナル.app の既定プロファイル（設定 > プロファイル で「デフォルト」にしたもの）の
    // 配色・フォントを読み込んで反映する。読めない項目は SwiftTerm の既定のまま。
    private func applyTerminalAppProfile() {
        let defaults = UserDefaults(suiteName: "com.apple.Terminal")
        guard let name = defaults?.string(forKey: "Default Window Settings"),
              let profiles = defaults?.dictionary(forKey: "Window Settings"),
              let profile = profiles[name] as? [String: Any] else { return }

        func color(_ key: String) -> NSColor? {
            guard let data = profile[key] as? Data,
                  let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else { return nil }
            return c.usingColorSpace(.sRGB)
        }

        if let data = profile["Font"] as? Data,
           let font = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data) {
            // ターミナル.app は等幅でないフォント（システムフォント等）も1文字ずつ詰めて表示するが、
            // SwiftTerm は最も幅の広い文字に合わせるため字間が大きく開く。その場合は同じサイズの等幅フォントにする
            terminalView.font = font.isFixedPitch
                ? font
                : NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        }

        let fg = color("TextColor")
        let bg = color("BackgroundColor")
        if let fg { terminalView.nativeForegroundColor = fg }
        if let bg { profileBackground = bg }
        if let blur = profile["BackgroundBlur"] as? Double, blur > 0 {
            profileBlur = Int32(blur * 40)
        }
        if let caret = color("CursorColor") { terminalView.caretColor = caret }
        if let selection = color("SelectionColor") { terminalView.selectedTextBackgroundColor = selection }
        if let option = profile["useOptionAsMetaKey"] as? Bool { terminalView.optionAsMetaKey = option }

        // 行間（1 が標準）
        if let height = profile["FontHeightSpacing"] as? Double, height > 0 {
            terminalView.lineSpacing = CGFloat(height)
        }

        // カーソルの形（0 = ブロック、1 = 下線、2 = 縦線）と点滅
        let blink = profile["CursorBlink"] as? Bool ?? false
        let cursorStyle: CursorStyle
        switch profile["CursorType"] as? Int ?? 0 {
        case 1: cursorStyle = blink ? .blinkUnderline : .steadyUnderline
        case 2: cursorStyle = blink ? .blinkBar : .steadyBar
        default: cursorStyle = blink ? .blinkBlock : .steadyBlock
        }
        terminalView.getTerminal().setCursorStyle(cursorStyle)

        // ベル（ターミナル.app では「音」は未設定なら ON、「画面フラッシュ」は未設定なら OFF）
        let audible = profile["Bell"] as? Bool ?? true
        let visual = profile["VisualBell"] as? Bool ?? false
        switch (audible, visual) {
        case (true, true): terminalView.bellStyle = .soundAndVisual
        case (true, false): terminalView.bellStyle = .sound
        case (false, true): terminalView.bellStyle = .visual
        case (false, false): terminalView.bellStyle = .none
        }

        let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        let keys = names.map { "ANSI\($0)Color" } + names.map { "ANSIBright\($0)Color" }
        let palette = keys.compactMap(color)
        if palette.count == 16 {
            terminalView.installColors(palette.map {
                SwiftTerm.Color(red: UInt16($0.redComponent * 65535),
                                green: UInt16($0.greenComponent * 65535),
                                blue: UInt16($0.blueComponent * 65535))
            })
        }

        // ステータスバーもターミナルの配色に合わせる
        statusLabel.textColor = (fg ?? .white).withAlphaComponent(0.6)
    }

    private func applyTransparency() {
        let level = transparencyLevel
        // 透過0%のときはプロファイルが半透明でも背景を塗りつぶし、ぼかしも切る
        let bg = level == 0 ? profileBackground.withAlphaComponent(1) : profileBackground
        terminalView.nativeBackgroundColor = bg
        statusBar.layer?.backgroundColor = bg.cgColor
        let translucent = bg.alphaComponent < 1
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : bg
        setBackgroundBlur(radius: translucent ? profileBlur : 0)
        window.alphaValue = level >= 2 ? 1.0 - CGFloat(level - 1) * 0.1 : 1.0
        updateStatus()
    }

    // ターミナル.app の「ぼかし」と同じ効果。公開APIがないため、iTerm2 なども使っている
    // CoreGraphics の非公開関数を実行時に探して呼ぶ（見つからなければ何もしない）
    private func setBackgroundBlur(radius: Int32) {
        typealias MainConnection = @convention(c) () -> Int32
        typealias SetBlur = @convention(c) (Int32, Int, Int32) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
              let connSym = dlsym(handle, "CGSMainConnectionID"),
              let blurSym = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return }
        let conn = unsafeBitCast(connSym, to: MainConnection.self)()
        _ = unsafeBitCast(blurSym, to: SetBlur.self)(conn, window.windowNumber, radius)
    }

    // MARK: - メニュー

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Floating Terminal を隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Floating Terminal を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "表示")
        floatingItem = NSMenuItem(title: "常に手前に表示", action: #selector(toggleFloating(_:)), keyEquivalent: "t")
        floatingItem.keyEquivalentModifierMask = [.command, .shift]
        floatingItem.target = self
        viewMenu.addItem(floatingItem)
        viewMenu.addItem(.separator())
        let moreOpaque = NSMenuItem(title: "不透明にする", action: #selector(increaseOpacity(_:)), keyEquivalent: "=")
        moreOpaque.target = self
        viewMenu.addItem(moreOpaque)
        let lessOpaque = NSMenuItem(title: "透明にする", action: #selector(decreaseOpacity(_:)), keyEquivalent: "-")
        lessOpaque.target = self
        viewMenu.addItem(lessOpaque)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(withTitle: "しまう", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func toggleFloating(_ sender: Any?) {
        isFloating.toggle()
        applyFloating()
        // 層を .normal に戻すと macOS が他のウインドウの後ろへ置き直すことがあるので、手前に出し直す
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func increaseOpacity(_ sender: Any?) {
        transparencyLevel = max(0, transparencyLevel - 1)
        applyTransparency()
    }

    @objc private func decreaseOpacity(_ sender: Any?) {
        transparencyLevel = min(maxTransparencyLevel, transparencyLevel + 1)
        applyTransparency()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        window.title = title.isEmpty ? "Floating Terminal" : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // exit でシェルを終えたらアプリも閉じる
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
