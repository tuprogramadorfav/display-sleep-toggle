import AppKit
import Carbon.HIToolbox
import IOKit
import os

// Toggles "Turn display off when inactive", on battery and on power adapter together, between Never and 10 minutes.
// Switches to Never while in clamshell mode and back to 10 minutes when the lid opens.
// Shortcuts swap with macOS's: Cmd + Brightness Down switches to Never and dims the built-in
// screen to minimum (the next Brightness Up restores the brightness and switches back to 10 minutes),
// and fn-Cmd-F1 toggles display mirroring instead.
// Built and started at login by ./module.nix (nix-darwin) or ./install.sh, which also install the sudoers rule it needs.

let pmset = "/usr/bin/pmset"
let onMinutes = 10

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

// Reads displaysleep from every power source section ("Battery Power:", "AC Power:") of `pmset -g custom`.
// Nil when they differ, which only happens after a change in System Settings.
func currentDisplaySleep() -> Int? {
    let values = run(pmset, ["-g", "custom"]).output.split(separator: "\n").compactMap { line -> Int? in
        let parts = line.split(separator: " ")
        return parts.count == 2 && parts[0] == "displaysleep" ? Int(parts[1]) : nil
    }
    return Set(values).count == 1 ? values.first : nil
}

func isLidClosed() -> Bool {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    defer { IOObjectRelease(root) }
    let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
    return value?.takeRetainedValue() as? Bool ?? false
}

// Built-in screen brightness (0...1). Apple Silicon has no public API for this, so it uses
// the private DisplayServices framework, loaded at runtime.
func displayServicesFunction<T>(_ name: String, as type: T.Type) -> T? {
    guard let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
          let symbol = dlsym(framework, name) else { return nil }
    return unsafeBitCast(symbol, to: type)
}

// Nil when the lid is closed, since the built-in screen is then offline.
func builtInDisplay() -> CGDirectDisplayID? {
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count)
    return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
}

func builtInBrightness() -> Float? {
    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    guard let display = builtInDisplay(),
          let getBrightness = displayServicesFunction("DisplayServicesGetBrightness", as: GetBrightness.self) else { return nil }
    var level: Float = 0
    return getBrightness(display, &level) == 0 ? level : nil
}

func setBuiltInBrightness(_ level: Float) {
    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    guard let display = builtInDisplay(),
          let setBrightness = displayServicesFunction("DisplayServicesSetBrightness", as: SetBrightness.self) else { return }
    _ = setBrightness(display, level)
}

// Carbon hot keys work system-wide without the Accessibility permission.
var hotKeyAction: (() -> Void)?

func registerHotKey(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
    hotKeyAction = action
    var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        hotKeyAction?()
        return noErr
    }, 1, &pressed, nil, nil)
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x4453_4c54), id: 1)  // "DSLT"
    RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
}

// Same as macOS's own mirroring shortcut: mirror every display to the main one, or stop mirroring.
func toggleMirroring() {
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count)
    let online = displays.prefix(Int(count))
    guard online.count > 1 else { return }
    let main = CGMainDisplayID()
    let mirrored = online.contains { CGDisplayIsInMirrorSet($0) != 0 }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return }
    for display in online where display != main {
        CGConfigureDisplayMirrorOfDisplay(config, display, mirrored ? kCGNullDirectDisplay : main)
    }
    CGCompleteDisplayConfiguration(config, .permanently)
}

// Cmd + Brightness Down can't be a hot key: the built-in keyboard sends the brightness keys as key
// codes 145 (down) and 144 (up) with fn held, and macOS acts on them before hot keys. A HID-level
// event tap sees them first and swallows the presses it handles, so macOS doesn't also toggle
// mirroring or step the brightness. Needs the Accessibility permission.
let keyLog = Logger(subsystem: "io.github.tuprogramadorfav.DisplaySleepToggle", category: "keys")
let brightnessDownKeyCode: Int64 = 145
let brightnessUpKeyCode: Int64 = 144
var brightnessKeyTap: CFMachPort?
var brightnessKeyTapSource: CFRunLoopSource?
var dimAction: (() -> Void)?
var undoDimAction: (() -> Void)?
// Brightness before Cmd + Brightness Down dimmed the screen. While set, the next Brightness Up undoes the dim.
var brightnessBeforeDim: Float?
// Swallows the rest of the Brightness Up press (repeats and key up) that triggered the undo.
var swallowingBrightnessUp = false

func installBrightnessKeyTap(dim: @escaping () -> Void, undoDim: @escaping () -> Void) -> Bool {
    dimAction = dim
    undoDimAction = undoDim
    guard let tap = CGEvent.tapCreate(
        tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue),
        callback: { _, type, event, _ in
            let pass = Unmanaged.passUnretained(event)
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = brightnessKeyTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return pass
            }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let modifiers = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
            let isPress = type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
            // The actions shell out to pmset, so they run after the callback returns.
            if code == brightnessDownKeyCode && modifiers == .maskCommand {
                if isPress {
                    keyLog.debug("Cmd + Brightness Down")
                    DispatchQueue.main.async { dimAction?() }
                }
                return nil
            }
            if code == brightnessUpKeyCode {
                if swallowingBrightnessUp {
                    if type == .keyUp { swallowingBrightnessUp = false }
                    return nil
                }
                if isPress && brightnessBeforeDim != nil && modifiers.subtracting(.maskCommand).isEmpty {
                    keyLog.debug("Brightness Up after dim")
                    swallowingBrightnessUp = true
                    DispatchQueue.main.async { undoDimAction?() }
                    return nil
                }
            }
            return pass
        },
        userInfo: nil
    ) else { return false }
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    brightnessKeyTap = tap
    brightnessKeyTapSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

// Whether the Accessibility permission is still granted. AXIsProcessTrusted and the other permission
// checks cache their answer for the life of the process, but WindowServer decides on every tap
// creation, so this creates a throwaway listen-only tap.
func canCreateKeyTap() -> Bool {
    guard let tap = CGEvent.tapCreate(
        tap: .cghidEventTap, place: .tailAppendEventTap, options: .listenOnly,
        eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
        callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil
    ) else { return false }
    CFMachPortInvalidate(tap)
    return true
}

// If the Accessibility permission is removed while the tap is installed, macOS stops delivering
// keyboard input to every app until the tap goes away, so it has to be removed right away.
// The retry timer in AppDelegate installs it again once the permission is back.
func removeBrightnessKeyTapIfRevoked() {
    guard let tap = brightnessKeyTap, !canCreateKeyTap() else { return }
    keyLog.notice("Accessibility permission removed, removing the key tap")
    CGEvent.tapEnable(tap: tap, enable: false)
    if let source = brightnessKeyTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    CFMachPortInvalidate(tap)
    brightnessKeyTap = nil
    brightnessKeyTapSource = nil
    brightnessBeforeDim = nil
    swallowingBrightnessUp = false
}

// A small on/off switch. Template image, so it follows the menu bar's colors like system icons.
// On: filled track with the knob cut out on the right. Off: outlined track with the knob on the left.
func switchImage(on: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 26, height: 15), flipped: false) { rect in
        let lineWidth: CGFloat = 1.5
        // The outline is stroked on its center line, so inset it to keep both states the same size.
        let trackRect = on ? rect : rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let track = NSBezierPath(roundedRect: trackRect, xRadius: trackRect.height / 2, yRadius: trackRect.height / 2)
        let inset: CGFloat = 3
        let knobSize = rect.height - inset * 2
        let knobX = on ? rect.maxX - inset - knobSize : rect.minX + inset
        let knob = NSBezierPath(ovalIn: NSRect(x: knobX, y: inset, width: knobSize, height: knobSize))
        NSColor.black.set()
        if on {
            track.append(knob)
            track.windingRule = .evenOdd
            track.fill()
        } else {
            track.lineWidth = lineWidth
            track.stroke()
            knob.fill()
        }
        return true
    }
    image.isTemplate = true
    return image
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?
    var trustTimer: Timer?
    var lidClosed = false
    // True when the clamshell automation switched to Never, so opening the lid should switch back.
    var restoreOnLidOpen = false

    func applicationDidFinishLaunching(_ note: Notification) {
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.delegate = self
        refresh()
        checkLid()
        registerHotKey(keyCode: kVK_F1, modifiers: cmdKey) { toggleMirroring() }
        if !installKeyTap() {
            // Shows the system prompt to allow Accessibility; the timer below retries until it's granted.
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
        // Closing or opening the lid turns the built-in display off or on.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.checkLid() }
        // Pick up changes made in System Settings.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkLid()
            self?.refresh()
            if brightnessKeyTap == nil { _ = self?.installKeyTap() }
        }
        // Checked twice a second, in every run loop mode, so a removed permission can't freeze the keyboard
        // for longer than that, even while a menu is open.
        trustTimer = Timer(timeInterval: 0.5, repeats: true) { _ in removeBrightnessKeyTapIfRevoked() }
        RunLoop.main.add(trustTimer!, forMode: .common)
    }

    func installKeyTap() -> Bool {
        installBrightnessKeyTap(dim: { [weak self] in self?.keepOnAndDim() },
                                undoDim: { [weak self] in self?.undoKeepOnAndDim() })
    }

    @objc func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func checkLid() {
        let closed = isLidClosed()
        guard closed != lidClosed else { return }
        lidClosed = closed
        if closed {
            if currentDisplaySleep() != 0 {
                setDisplaySleep(0)
                restoreOnLidOpen = true
            }
        } else if restoreOnLidOpen {
            restoreOnLidOpen = false
            if currentDisplaySleep() == 0 { setDisplaySleep(onMinutes) }
        }
    }

    func refresh() {
        let minutes = currentDisplaySleep()
        let image = switchImage(on: minutes == 0)
        image.accessibilityDescription = minutes == 0 ? "Keep display on: on" : "Keep display on: off"
        item.button?.image = image
        item.button?.toolTip = switch minutes {
        case nil: "Display sleep differs on battery and power adapter"
        case 0: "Display stays on (never sleeps)"
        case let m?: "Display sleeps after \(m) min"
        }
    }

    @objc func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            toggle()
        }
    }

    @objc func toggle() {
        // A manual choice wins over the clamshell automation and the dim undo.
        restoreOnLidOpen = false
        brightnessBeforeDim = nil
        setDisplaySleep(currentDisplaySleep() == 0 ? onMinutes : 0)
    }

    @objc func keepOnAndDim() {
        // A manual choice wins over the clamshell automation.
        restoreOnLidOpen = false
        // Pressing it again while dimmed keeps the original brightness to return to.
        if brightnessBeforeDim == nil { brightnessBeforeDim = builtInBrightness() }
        if currentDisplaySleep() != 0 { setDisplaySleep(0) }
        setBuiltInBrightness(0)
    }

    func undoKeepOnAndDim() {
        guard let level = brightnessBeforeDim else { return }
        brightnessBeforeDim = nil
        setBuiltInBrightness(level)
        setDisplaySleep(onMinutes)
    }

    func setDisplaySleep(_ minutes: Int) {
        let result = run("/usr/bin/sudo", ["-n", pmset, "-a", "displaysleep", String(minutes)])
        if result.status != 0 {
            let alert = NSAlert()
            alert.messageText = "Could not change display sleep"
            alert.informativeText = "The passwordless sudo rule for pmset is missing. Run install.sh again, or enable the nix-darwin module (see the README).\n\n\(result.output)"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        let minutes = currentDisplaySleep()
        let status = minutes == 0 ? "Display sleep: Never" : "Display sleep: \(minutes.map { "\($0) min" } ?? "differs on battery and power adapter")"
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))
        let dim = NSMenuItem(title: "Keep On and Dim Screen (⌘ Brightness Down)", action: #selector(keepOnAndDim), keyEquivalent: "")
        dim.target = self
        menu.addItem(dim)
        if brightnessKeyTap == nil {
            let allow = NSMenuItem(title: "Allow Accessibility for ⌘ Brightness Down…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            allow.target = self
            menu.addItem(allow)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
