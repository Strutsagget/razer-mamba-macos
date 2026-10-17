// RazerToggle – menyradsikon som styr belysningen på Razer Mamba via razerctl.
// Vänsterklick: växla av/på. Högerklick: meny med färger, effekter och ljusstyrka.

import AppKit

let razerctlPath = "/usr/local/bin/razerctl"

enum Effect: String, CaseIterable {
    case staticColor = "static", spectrum, wave, breathing, breathingRandom, reactive

    var title: String {
        switch self {
        case .staticColor:     return "Fast färg"
        case .spectrum:        return "Regnbåge"
        case .wave:            return "Våg"
        case .breathing:       return "Andning"
        case .breathingRandom: return "Andning (slumpade färger)"
        case .reactive:        return "Lyser vid klick"
        }
    }

    var usesColor: Bool { [.staticColor, .breathing, .reactive].contains(self) }

    func args(_ c: RGB) -> [String] {
        let rgb = [c.r, c.g, c.b].map(String.init)
        switch self {
        case .staticColor:     return ["static"] + rgb
        case .spectrum:        return ["spectrum"]
        case .wave:            return ["wave"]
        case .breathing:       return ["breathing"] + rgb
        case .breathingRandom: return ["breathing"]
        case .reactive:        return ["reactive"] + rgb
        }
    }
}

struct RGB: Equatable {
    var r, g, b: Int
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
    }
    init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }
    init(_ c: NSColor) {
        let s = c.usingColorSpace(.sRGB) ?? c
        r = Int((s.redComponent * 255).rounded())
        g = Int((s.greenComponent * 255).rounded())
        b = Int((s.blueComponent * 255).rounded())
    }
}

let presets: [(String, RGB)] = [
    ("Razer-grön", RGB(r: 0x44, g: 0xD6, b: 0x2C)),
    ("Röd",        RGB(r: 255, g: 0,   b: 0)),
    ("Orange",     RGB(r: 255, g: 100, b: 0)),
    ("Gul",        RGB(r: 255, g: 220, b: 0)),
    ("Blå",        RGB(r: 0,   g: 60,  b: 255)),
    ("Cyan",       RGB(r: 0,   g: 220, b: 255)),
    ("Lila",       RGB(r: 160, g: 0,   b: 255)),
    ("Rosa",       RGB(r: 255, g: 0,   b: 140)),
    ("Vit",        RGB(r: 255, g: 255, b: 255)),
]

// Sparade inställningar
final class Settings {
    private let d = UserDefaults.standard
    var lightsOn: Bool {
        get { d.object(forKey: "lightsOn") as? Bool ?? true }
        set { d.set(newValue, forKey: "lightsOn") }
    }
    var effect: Effect {
        get { Effect(rawValue: d.string(forKey: "effect") ?? "") ?? .spectrum }
        set { d.set(newValue.rawValue, forKey: "effect") }
    }
    var color: RGB {
        get {
            guard let a = d.array(forKey: "color") as? [Int], a.count == 3 else { return presets[0].1 }
            return RGB(r: a[0], g: a[1], b: a[2])
        }
        set { d.set([newValue.r, newValue.g, newValue.b], forKey: "color") }
    }
    var brightness: Int {
        get { d.object(forKey: "brightness") as? Int ?? 255 }
        set { d.set(newValue, forKey: "brightness") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let settings = Settings()
    private let slider = NSSlider(value: 255, minValue: 0, maxValue: 255, target: nil, action: nil)
    private var debounce: [String: Timer] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self
        menu.autoenablesItems = false
        updateIcon()
    }

    // MARK: Klick

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil   // annars tar menyn över vänsterklicket
        } else {
            settings.lightsOn ? turnOff() : turnOn()
        }
    }

    // MARK: Meny (byggs om varje gång den öppnas så bockarna stämmer)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let on = settings.lightsOn

        add(menu, on ? "Släck" : "Tänd", #selector(toggle))
        menu.addItem(.separator())

        menu.addItem(header("Färg"))
        for (i, (name, rgb)) in presets.enumerated() {
            let item = add(menu, name, #selector(pickPreset(_:)))
            item.tag = i
            item.image = swatch(rgb.nsColor)
            item.state = on && settings.effect.usesColor && settings.color == rgb ? .on : .off
        }
        let custom = add(menu, "Välj färg…", #selector(openColorPanel))
        custom.image = swatch(settings.color.nsColor)
        menu.addItem(.separator())

        menu.addItem(header("Effekt"))
        for (i, effect) in Effect.allCases.enumerated() {
            let item = add(menu, effect.title, #selector(pickEffect(_:)))
            item.tag = i
            item.state = on && settings.effect == effect ? .on : .off
        }
        menu.addItem(.separator())

        menu.addItem(header("Ljusstyrka"))
        menu.addItem(sliderItem())
        menu.addItem(.separator())

        menu.addItem(withTitle: "Avsluta", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
    }

    private func sliderItem() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        slider.frame = NSRect(x: 20, y: 4, width: 180, height: 20)
        slider.integerValue = settings.brightness
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(brightnessChanged)
        view.addSubview(slider)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    // MARK: Åtgärder

    @objc private func toggle() { settings.lightsOn ? turnOff() : turnOn() }

    private func turnOn() {
        settings.lightsOn = true
        run(["brightness", String(max(settings.brightness, 1))])
        run(settings.effect.args(settings.color))
        updateIcon()
    }

    private func turnOff() {
        settings.lightsOn = false
        run(["off"])
        updateIcon()
    }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        setColor(presets[sender.tag].1)
    }

    @objc private func pickEffect(_ sender: NSMenuItem) {
        settings.effect = Effect.allCases[sender.tag]
        turnOn()
    }

    // En färg byter till "Fast färg" om nuvarande effekt inte använder färg
    private func setColor(_ rgb: RGB) {
        settings.color = rgb
        if !settings.effect.usesColor { settings.effect = .staticColor }
        turnOn()
    }

    @objc private func openColorPanel() {
        let panel = NSColorPanel.shared
        panel.color = settings.color.nsColor
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelChanged(_ panel: NSColorPanel) {
        let rgb = RGB(panel.color)
        later("color") { self.setColor(rgb) }
    }

    @objc private func brightnessChanged() {
        let value = slider.integerValue
        settings.brightness = value
        later("brightness") {
            if value == 0 { self.turnOff() }
            else if !self.settings.lightsOn { self.turnOn() }
            else { self.run(["brightness", String(value)]) }
        }
    }

    // Väntar tills reglaget/färgväljaren stått still en kort stund innan musen uppdateras
    private func later(_ key: String, _ block: @escaping () -> Void) {
        debounce[key]?.invalidate()
        // .common så att timern även går medan menyn är öppen (event tracking-läge)
        let timer = Timer(timeInterval: 0.12, repeats: false) { _ in block() }
        RunLoop.main.add(timer, forMode: .common)
        debounce[key] = timer
    }

    private func updateIcon() {
        let on = settings.lightsOn
        let image = NSImage(systemSymbolName: on ? "computermouse.fill" : "computermouse",
                            accessibilityDescription: "Razer-belysning")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = on ? "Razer: tänd (klicka för att släcka)"
                                        : "Razer: släckt (klicka för att tända)"
    }

    @discardableResult
    private func run(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: razerctlPath)
        p.arguments = args
        p.environment = ["RAZER_DEBUG": "1"]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log("razerctl \(args.joined(separator: " ")) -> exit \(p.terminationStatus)\n\(output)")
            if p.terminationStatus != 0 { NSSound.beep() }
            return p.terminationStatus == 0
        } catch {
            log("kunde inte starta razerctl: \(error)")
            NSSound.beep()
            return false
        }
    }
}

// Loggfil: ~/Library/Logs/RazerToggle.log
func log(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/RazerToggle.log")
    let line = "\(Date()) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // ingen Dock-ikon
app.run()
