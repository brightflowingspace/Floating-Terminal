import Cocoa
import SwiftTerm

// 常に最前面に表示できるターミナル。
// 中身は SwiftTerm の LocalProcessTerminalView で、ログインシェル（zsh）をそのまま動かす。
// ⌘T で macOS 標準のタブを追加でき、タブごとに別のシェルが動く。

private let floatingKey = "floatingEnabled"
private let transparencyKey = "transparencyLevel"
private let frameAutosaveName = "FloatingTerminalMainWindow"
private let tabbingID = "FloatingTerminalTabs"

// MARK: - ターミナル.app のプロファイル

// ターミナル.app の既定プロファイル（設定 > プロファイル で「デフォルト」にしたもの）から読んだ設定。
// 起動時と、Floating Terminal が前面に戻ってきたときに読み、全タブで共有する。
// 読めない項目は nil のままにして SwiftTerm の既定を使う。
struct TerminalProfile {
    var font: NSFont?
    var foreground: NSColor?
    var background: NSColor = .black
    var blur: Int32 = 0
    var caret: NSColor?
    var selection: NSColor?
    var optionAsMeta: Bool?
    var lineSpacing: CGFloat?
    var cursorStyle: CursorStyle = .steadyBlock
    var bellStyle: BellStyle = .sound
    var palette: [SwiftTerm.Color]?
    // 読み込んだ元のプロファイル（名前と中身）。前回から変わったかどうかの比較に使う
    var source: NSDictionary?

    static func loadDefault() -> TerminalProfile {
        var result = TerminalProfile()
        // 他のアプリ（ターミナル.app）が書き換えた最新の設定を読むために同期する
        CFPreferencesAppSynchronize("com.apple.Terminal" as CFString)
        let defaults = UserDefaults(suiteName: "com.apple.Terminal")
        guard let name = defaults?.string(forKey: "Default Window Settings"),
              let profiles = defaults?.dictionary(forKey: "Window Settings"),
              let profile = profiles[name] as? [String: Any] else { return result }
        result.source = [name: profile] as NSDictionary

        func color(_ key: String) -> NSColor? {
            guard let data = profile[key] as? Data,
                  let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else { return nil }
            return c.usingColorSpace(.sRGB)
        }

        if let data = profile["Font"] as? Data,
           let font = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data) {
            // ターミナル.app は等幅でないフォント（システムフォント等）も1文字ずつ詰めて表示するが、
            // SwiftTerm は最も幅の広い文字に合わせるため字間が大きく開く。その場合は同じサイズの等幅フォントにする
            result.font = font.isFixedPitch
                ? font
                : NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        }

        result.foreground = color("TextColor")
        if let bg = color("BackgroundColor") { result.background = bg }
        if let blur = profile["BackgroundBlur"] as? Double, blur > 0 {
            result.blur = Int32(blur * 40)
        }
        result.caret = color("CursorColor")
        result.selection = color("SelectionColor")
        result.optionAsMeta = profile["useOptionAsMetaKey"] as? Bool

        // 行間（1 が標準）
        if let height = profile["FontHeightSpacing"] as? Double, height > 0 {
            result.lineSpacing = CGFloat(height)
        }

        // カーソルの形（0 = ブロック、1 = 下線、2 = 縦線）と点滅
        let blink = profile["CursorBlink"] as? Bool ?? false
        switch profile["CursorType"] as? Int ?? 0 {
        case 1: result.cursorStyle = blink ? .blinkUnderline : .steadyUnderline
        case 2: result.cursorStyle = blink ? .blinkBar : .steadyBar
        default: result.cursorStyle = blink ? .blinkBlock : .steadyBlock
        }

        // ベル（ターミナル.app では「音」は未設定なら ON、「画面フラッシュ」は未設定なら OFF）
        let audible = profile["Bell"] as? Bool ?? true
        let visual = profile["VisualBell"] as? Bool ?? false
        switch (audible, visual) {
        case (true, true): result.bellStyle = .soundAndVisual
        case (true, false): result.bellStyle = .sound
        case (false, true): result.bellStyle = .visual
        case (false, false): result.bellStyle = .none
        }

        let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        let keys = names.map { "ANSI\($0)Color" } + names.map { "ANSIBright\($0)Color" }
        let colors = keys.compactMap(color)
        if colors.count == 16 {
            result.palette = colors.map {
                SwiftTerm.Color(red: UInt16($0.redComponent * 65535),
                                green: UInt16($0.greenComponent * 65535),
                                blue: UInt16($0.blueComponent * 65535))
            }
        }
        return result
    }
}

// MARK: - タブ1つ分（ウインドウ＋シェル）

// ファイルやURLをドラッグ＆ドロップすると、その場所(パス)やURLを入力する。ターミナル.app と同じ動き。
// ファイルはシェル用にエスケープしたパスを、複数ならスペース区切りで、最後にスペースを1つ付けて入力する。
// スクショ（撮影直後に左下に出るサムネイルのドラッグ、クリップボードの画像の ⌘V）は
// 一時フォルダに PNG として保存し、そのパスを入力する。Claude Code はパスを画像として読み込む。
final class DropTerminalView: LocalProcessTerminalView {
    // スクショなどの画像を置く場所。再起動で macOS が片付ける一時フォルダの中に作る
    private static let imageDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FloatingTerminal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerDropTypes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerDropTypes()
    }

    private func registerDropTypes() {
        registerForDraggedTypes([.fileURL, .URL, .string] + Self.imageTypes
                                + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        let canDrop = pasteboard.canReadObject(forClasses: [NSURL.self, NSFilePromiseReceiver.self], options: nil)
            || pasteboard.availableType(from: [.string] + Self.imageTypes) != nil
        return canDrop ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)

        // 実ファイルがあるときはそれを優先（Finder からのドラッグなど）
        if let text = fileText(from: pasteboard) ?? imageText(from: pasteboard) {
            paste(text: text)
            return true
        }
        // スクショのサムネイルは「ファイルの約束」だけを渡してくるので、受け取ってから書き出してもらう
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver], !receivers.isEmpty {
            receivePromises(receivers)
            return true
        }
        if let text = urlText(from: pasteboard) ?? pasteboard.string(forType: .string), !text.isEmpty {
            paste(text: text)
            return true
        }
        return false
    }

    // ⌘V。文字がなければ、コピーしたファイルのパスや、クリップボードの画像（スクショ）のパスを貼る
    override func paste(_ sender: Any) {
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) == nil,
           let text = fileText(from: pasteboard) ?? imageText(from: pasteboard) {
            paste(text: text)
            return
        }
        super.paste(sender)
    }

    // シェルや Claude Code が「貼り付け」と分かるよう、対応していれば括弧付きペーストで送る
    private func paste(text: String) {
        if getTerminal().bracketedPasteMode {
            send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
        } else {
            send(txt: text)
        }
    }

    private func pathsText(_ urls: [URL]) -> String {
        urls.map { Self.shellEscaped($0.path) }.joined(separator: " ") + " "
    }

    private func fileText(from pasteboard: NSPasteboard) -> String? {
        let fileOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let files = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOnly) as? [URL],
              !files.isEmpty else { return nil }
        return pathsText(files)
    }

    private func urlText(from pasteboard: NSPasteboard) -> String? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return nil }
        return urls.map(\.absoluteString).joined(separator: " ")
    }

    // 画像そのものが入っているとき（⌃⇧⌘4 でクリップボードに撮ったスクショなど）は PNG に書き出す
    private func imageText(from pasteboard: NSPasteboard) -> String? {
        guard let type = pasteboard.availableType(from: Self.imageTypes),
              let data = pasteboard.data(forType: type) else { return nil }
        let png: Data?
        if type == .png {
            png = data
        } else {
            png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        let url = Self.uniqueURL(in: Self.imageDirectory, name: "screenshot_\(formatter.string(from: Date())).png")
        guard let png, (try? png.write(to: url)) != nil else { return nil }
        return pathsText([url])
    }

    private func receivePromises(_ receivers: [NSFilePromiseReceiver]) {
        // 受け取り先は毎回別のフォルダにして、同じ名前のファイルがぶつからないようにする
        let dir = Self.imageDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let group = DispatchGroup()
        var received: [URL] = []
        let lock = NSLock()
        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { url, error in
                if error == nil {
                    lock.lock(); received.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, !received.isEmpty else { return }
            self.paste(text: self.pathsText(received))
        }
    }

    private static func uniqueURL(in dir: URL, name: String) -> URL {
        var url = dir.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)_\(n).png")
            n += 1
        }
        return url
    }

    // 空白や記号の前に \ を付ける(ターミナル.app のドロップと同じ形)
    private static func shellEscaped(_ path: String) -> String {
        let special = Set(" \\'\"`$&*?!|;<>()[]{}#~^%=,")
        return path.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
    }
}

final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate, NSWindowDelegate {
    let window: NSWindow
    let terminalView: LocalProcessTerminalView
    private let statusBar: NSView
    private let statusLabel: NSTextField
    private var profile: TerminalProfile
    var onClose: ((TerminalSession) -> Void)?

    init(profile: TerminalProfile) {
        self.profile = profile
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Floating Terminal"
        window.isReleasedWhenClosed = false
        // フルスクリーンのアプリの上にも重ねられるようにする
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.tabbingMode = .preferred
        window.tabbingIdentifier = tabbingID

        let container = NSView(frame: window.contentView!.bounds)
        container.autoresizingMask = [.width, .height]

        let barHeight: CGFloat = 22
        var termFrame = container.bounds
        termFrame.origin.y = barHeight
        termFrame.size.height -= barHeight
        terminalView = DropTerminalView(frame: termFrame)
        terminalView.autoresizingMask = [.width, .height]
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
        super.init()

        window.delegate = self
        terminalView.processDelegate = self
        applyProfile()
    }

    // ターミナル.app の設定が変わったときに、開いているタブへ反映し直す
    func update(profile newProfile: TerminalProfile) {
        profile = newProfile
        applyProfile()
    }

    private func applyProfile() {
        terminalView.font = profile.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        if let fg = profile.foreground { terminalView.nativeForegroundColor = fg }
        if let caret = profile.caret { terminalView.caretColor = caret }
        if let selection = profile.selection { terminalView.selectedTextBackgroundColor = selection }
        if let option = profile.optionAsMeta { terminalView.optionAsMetaKey = option }
        if let spacing = profile.lineSpacing { terminalView.lineSpacing = spacing }
        terminalView.getTerminal().setCursorStyle(profile.cursorStyle)
        terminalView.bellStyle = profile.bellStyle
        if let palette = profile.palette { terminalView.installColors(palette) }
        // ステータスバーもターミナルの配色に合わせる
        statusLabel.textColor = (profile.foreground ?? .white).withAlphaComponent(0.6)
    }

    func startShell(in directory: String?) {
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
                                  execName: execName, currentDirectory: directory ?? home)
    }

    // シェルが今いるフォルダ。macOS の proc_pidinfo でシェルのプロセスから直接読む
    var currentDirectory: String? {
        guard let pid = terminalView.process?.shellPid, pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    func apply(floating: Bool, transparencyLevel level: Int, status: String) {
        window.level = floating ? .floating : .normal

        // 透過0%のときはプロファイルが半透明でも背景を塗りつぶし、ぼかしも切る
        let bg = level == 0 ? profile.background.withAlphaComponent(1) : profile.background
        terminalView.nativeBackgroundColor = bg
        statusBar.layer?.backgroundColor = bg.cgColor
        let translucent = bg.alphaComponent < 1
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : bg
        setBackgroundBlur(radius: translucent ? profile.blur : 0)
        window.alphaValue = level >= 2 ? 1.0 - CGFloat(level - 1) * 0.1 : 1.0

        statusLabel.attributedStringValue = statusString(floating: floating, text: status,
                                                         background: bg.withAlphaComponent(1))
    }

    // ステータスバーの文字。手前表示の前に SF Symbols の ⌘ アイコンを文字色で付ける
    // ON / OFF の文字は、文字色で塗った角丸の背景に背景色の文字で抜いて目立たせる
    private func statusString(floating: Bool, text: String, background: NSColor) -> NSAttributedString {
        let color = statusLabel.textColor ?? .white
        let font = statusLabel.font ?? NSFont.systemFont(ofSize: 11)
        // ターミナル.app と見分けられるよう、先頭にアプリ名とバージョンを出す
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let result = NSMutableAttributedString(string: "Floating Terminal v\(version)　　")
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize + 3, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let icon = NSImage(systemSymbolName: "command",
                             accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let attachment = NSTextAttachment()
            attachment.image = icon
            // 文字の高さの中央に揃える
            attachment.bounds = NSRect(x: 0, y: (font.capHeight - icon.size.height) / 2,
                                       width: icon.size.width, height: icon.size.height)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " "))
        }
        let state = floating ? "ON" : "OFF"
        let marker = "常に手前に表示：" + state
        if let range = text.range(of: marker) {
            result.append(NSAttributedString(string: String(text[..<range.lowerBound]) + "常に手前に表示："))
            result.append(badge(state, font: font, fill: color, textColor: background))
            result.append(NSAttributedString(string: " " + String(text[range.upperBound...])))
        } else {
            result.append(NSAttributedString(string: text))
        }
        result.addAttributes([.font: font, .foregroundColor: color],
                             range: NSRange(location: 0, length: result.length))
        return result
    }

    private func badge(_ text: String, font: NSFont, fill: NSColor, textColor: NSColor) -> NSAttributedString {
        let boldFont = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        let label = NSAttributedString(string: text, attributes: [.font: boldFont, .foregroundColor: textColor])
        let textSize = label.size()
        let size = NSSize(width: ceil(textSize.width) + 10, height: ceil(textSize.height) + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            label.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2))
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        // 文字の高さの中央に揃える
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
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

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // タブ（ウインドウ）を閉じたら、そのシェルも終了させる
        if let pid = terminalView.process?.shellPid, pid > 0 {
            kill(pid, SIGHUP)
        }
        terminalView.process?.terminate()
        onClose?(self)
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        window.title = title.isEmpty ? "Floating Terminal" : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // exit でシェルを終えたらそのタブを閉じる（最後の1つならアプリも終了する）
        DispatchQueue.main.async { [weak self] in self?.window.close() }
    }
}

// MARK: - アプリ全体

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sessions: [TerminalSession] = []
    private var profile = TerminalProfile()
    private var floatingItem: NSMenuItem!

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        profile = TerminalProfile.loadDefault()
        buildMenu()
        let first = makeSession(directory: nil)
        first.window.center()
        first.window.setFrameAutosaveName(frameAutosaveName)
        first.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Floating Terminal が前面に戻ってきたら、ターミナル.app の設定を読み直す。
    // 変わっていたら、開いているすべてのタブに反映する（色・フォント・透過など）
    func applicationDidBecomeActive(_ notification: Notification) {
        let latest = TerminalProfile.loadDefault()
        guard latest.source != profile.source else { return }
        profile = latest
        for session in sessions {
            session.update(profile: latest)
            applySettings(to: session)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private var activeSession: TerminalSession? {
        sessions.first { $0.window.isKeyWindow } ?? sessions.first { $0.window.isMainWindow } ?? sessions.last
    }

    private func makeSession(directory: String?) -> TerminalSession {
        let session = TerminalSession(profile: profile)
        session.onClose = { [weak self] closed in
            self?.sessions.removeAll { $0 === closed }
        }
        sessions.append(session)
        applySettings(to: session)
        session.startShell(in: directory)
        return session
    }

    // MARK: 設定の反映（全タブ共通）

    private var statusText: String {
        let floating = isFloating
            ? "常に手前に表示：ON（⌘⇧T でOFF）"
            : "常に手前に表示：OFF（⌘⇧T でON）"
        let transparency: String
        switch transparencyLevel {
        case 0: transparency = "0%"
        case 1: transparency = "ターミナルと同じ"
        default: transparency = "\((transparencyLevel - 1) * 10)%"
        }
        return "\(floating)　　透過：\(transparency)（⌘- / ⌘=）"
    }

    private func applySettings(to session: TerminalSession) {
        session.apply(floating: isFloating, transparencyLevel: transparencyLevel, status: statusText)
    }

    private func applySettingsToAll() {
        sessions.forEach(applySettings)
        floatingItem.state = isFloating ? .on : .off
    }

    // MARK: メニュー

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "設定…", action: #selector(openTerminalSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Floating Terminal を隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Floating Terminal を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let shellItem = NSMenuItem()
        let shellMenu = NSMenu(title: "シェル")
        let newTab = NSMenuItem(title: "新規タブ", action: #selector(newTab(_:)), keyEquivalent: "t")
        newTab.target = self
        shellMenu.addItem(newTab)
        shellMenu.addItem(.separator())
        let openTerminal = NSMenuItem(title: "このフォルダをターミナルで開く", action: #selector(openInTerminalApp(_:)), keyEquivalent: "")
        openTerminal.target = self
        shellMenu.addItem(openTerminal)
        shellMenu.addItem(.separator())
        shellMenu.addItem(withTitle: "タブを閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        shellItem.submenu = shellMenu
        mainMenu.addItem(shellItem)

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
        floatingItem.state = isFloating ? .on : .off
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

        // windowsMenu に登録すると、macOS が「次のタブを表示」などのタブ操作を自動で追加する
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(withTitle: "しまう", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func newTab(_ sender: Any?) {
        guard let current = activeSession else {
            let session = makeSession(directory: nil)
            session.window.makeKeyAndOrderFront(nil)
            return
        }
        // 新しいタブは今のタブと同じフォルダで開く
        let session = makeSession(directory: current.currentDirectory)
        current.window.addTabbedWindow(session.window, ordered: .above)
        session.window.makeKeyAndOrderFront(nil)
    }

    // タブバーの「＋」ボタンから呼ばれる
    @objc func newWindowForTab(_ sender: Any?) {
        newTab(sender)
    }

    @objc private func openInTerminalApp(_ sender: Any?) {
        guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        let config = NSWorkspace.OpenConfiguration()
        if let dir = activeSession?.currentDirectory {
            // フォルダを渡すと、ターミナル.app がそのフォルダで新しいウインドウを開く
            NSWorkspace.shared.open([URL(fileURLWithPath: dir, isDirectory: true)],
                                    withApplicationAt: terminalURL, configuration: config)
        } else {
            NSWorkspace.shared.openApplication(at: terminalURL, configuration: config)
        }
    }

    // 設定は ターミナル.app の設定画面を使う（Floating Terminal はそこから配色などを読み込むため）。
    // ターミナル.app には設定画面を開く命令がないので、前面に出してから ⌘, を送る。
    // キー送信には「アクセシビリティ」の許可が必要なので、許可がなければ システム設定 のその画面を開く
    @objc private func openTerminalSettings(_ sender: Any?) {
        guard AXIsProcessTrusted() else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let source = """
        tell application "Terminal" to activate
        delay 0.3
        tell application "System Events" to tell process "Terminal" to keystroke "," using command down
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("ターミナルの設定を開けませんでした: \(error)") }
    }

    @objc private func toggleFloating(_ sender: Any?) {
        isFloating.toggle()
        applySettingsToAll()
        // 層を .normal に戻すと macOS が他のウインドウの後ろへ置き直すことがあるので、手前に出し直す
        activeSession?.window.makeKeyAndOrderFront(nil)
    }

    @objc private func increaseOpacity(_ sender: Any?) {
        transparencyLevel = max(0, transparencyLevel - 1)
        applySettingsToAll()
    }

    @objc private func decreaseOpacity(_ sender: Any?) {
        transparencyLevel = min(maxTransparencyLevel, transparencyLevel + 1)
        applySettingsToAll()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
