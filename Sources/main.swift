@preconcurrency import ApplicationServices
import AppKit
import Carbon.HIToolbox
import CryptoKit
import Darwin
import Foundation

struct ConfigFile: Decodable {
    let port: Int
}

struct Envelope<T: Encodable>: Encodable {
    let type: String
    let payload: T
}

struct RegisterPayload: Encodable {
    let pid: Int32
    let name: String
    let version: String
}

struct HotkeyPayload: Encodable {
    let action: String
    let combo: String
}

struct EdgePayload: Encodable {
    let edge: String
    let pct: Double
}

struct InputPayload: Codable {
    let kind: String
    let dx: Double?
    let dy: Double?
    let key_code: Int64?
    let modifiers: Int64?
    let text: String?
    let button: String?
    let pressed: Bool?
}

struct AckPayload: Decodable {
    let message: String?
}

struct DaemonInfo: Decodable {
    let device_id: String
    let display_id: String
    let name: String
}

struct SessionInfo: Decodable {
    let connection_id: String
    let device_id: String
    let name: String
    let role: String
}

struct ConfigPushPayload: Decodable {
    let daemon: DaemonInfo
    let sessions: [SessionInfo]
    let hotkeys: [String: String]
    let edge_targets: [String: String]
    let active_target: String
    let paused: Bool
}

struct ParsedHotkey {
    let action: String
    let combo: String
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags
}

let emergencyReturnCombo = "ctrl+alt+escape"
let emergencyReturnKeyCode = CGKeyCode(kVK_Escape)
let emergencyReturnModifiers: CGEventFlags = [.maskControl, .maskAlternate]

final class HelperState: @unchecked Sendable {
    private let lock = NSLock()
    private var daemonDeviceID = ""
    private var activeTarget = ""
    private var paused = false
    private var edgeTargets: [String: String] = [:]
    private var requireEdgeNeutral = false
    private var suppressEdgesUntil = Date.distantPast

    func update(from payload: ConfigPushPayload) {
        lock.lock()
        let previousTarget = activeTarget
        daemonDeviceID = payload.daemon.device_id
        activeTarget = payload.active_target
        paused = payload.paused
        edgeTargets = payload.edge_targets
        if !daemonDeviceID.isEmpty && previousTarget != daemonDeviceID && activeTarget == daemonDeviceID {
            requireEdgeNeutral = true
            suppressEdgesUntil = max(suppressEdgesUntil, Date().addingTimeInterval(1.5))
        }
        lock.unlock()
    }

    func shouldForwardInput() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !paused && !daemonDeviceID.isEmpty && activeTarget != daemonDeviceID
    }

    func allowEdgeSwitch(detectedEdge: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !paused && !daemonDeviceID.isEmpty && activeTarget == daemonDeviceID else {
            return false
        }
        if Date() < suppressEdgesUntil {
            return false
        }
        if requireEdgeNeutral {
            if !detectedEdge {
                requireEdgeNeutral = false
            }
            return false
        }
        return true
    }

    func suppressEdgeSwitching(for duration: TimeInterval) {
        lock.lock()
        suppressEdgesUntil = max(suppressEdgesUntil, Date().addingTimeInterval(duration))
        requireEdgeNeutral = true
        lock.unlock()
    }

    func edgeTarget(for edge: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return edgeTargets[edge] ?? ""
    }
}

final class InjectionGuard: @unchecked Sendable {
    private struct Entry {
        let signature: String
        let expiresAt: Date
    }

    private let lock = NSLock()
    private let window: TimeInterval = 0.25
    private var entries: [Entry] = []

    func record(_ signature: String) {
        lock.lock()
        purgeLocked(now: Date())
        entries.append(Entry(signature: signature, expiresAt: Date().addingTimeInterval(window)))
        lock.unlock()
    }

    func shouldIgnore(signature: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        purgeLocked(now: now)
        guard let index = entries.firstIndex(where: { $0.signature == signature }) else {
            return false
        }
        entries.remove(at: index)
        return true
    }

    private func purgeLocked(now: Date) {
        entries.removeAll { $0.expiresAt <= now }
    }
}

final class CaptureSuppressionState: @unchecked Sendable {
    private let lock = NSLock()
    private var suppressMouseUntil = Date.distantPast
    private var suppressButtonsUntil = Date.distantPast
    private var suppressScrollUntil = Date.distantPast
    private var suppressKeysUntil = Date.distantPast

    func record(for input: InputPayload) {
        lock.lock()
        let now = Date()
        switch input.kind {
        case "mouse_move":
            suppressMouseUntil = max(suppressMouseUntil, now.addingTimeInterval(0.035))
        case "mouse_button":
            suppressButtonsUntil = max(suppressButtonsUntil, now.addingTimeInterval(0.05))
            suppressMouseUntil = max(suppressMouseUntil, now.addingTimeInterval(0.02))
        case "scroll":
            suppressScrollUntil = max(suppressScrollUntil, now.addingTimeInterval(0.05))
        case "key_down", "key_up", "key_tap":
            suppressKeysUntil = max(suppressKeysUntil, now.addingTimeInterval(0.035))
        case "text":
            suppressKeysUntil = max(suppressKeysUntil, now.addingTimeInterval(0.035))
        default:
            break
        }
        lock.unlock()
    }

    func shouldIgnore(type: CGEventType) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return now < suppressMouseUntil
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return now < suppressButtonsUntil
        case .scrollWheel:
            return now < suppressScrollUntil
        case .keyDown, .keyUp, .flagsChanged:
            return now < suppressKeysUntil
        default:
            return false
        }
    }
}

final class ModifierState {
    private let lock = NSLock()
    private var lastFlags = CGEventFlags()

    func transition(for keyCode: CGKeyCode, flags: CGEventFlags) -> Bool? {
        guard let modifierFlag = modifierFlag(for: keyCode) else {
            return nil
        }

        lock.lock()
        defer {
            lastFlags = flags
            lock.unlock()
        }

        let wasPressed = lastFlags.contains(modifierFlag)
        let isPressed = flags.contains(modifierFlag)
        if wasPressed == isPressed {
            return nil
        }
        return isPressed
    }

    private func modifierFlag(for keyCode: CGKeyCode) -> CGEventFlags? {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand:
            return .maskCommand
        case kVK_Shift, kVK_RightShift:
            return .maskShift
        case kVK_Option, kVK_RightOption:
            return .maskAlternate
        case kVK_Control, kVK_RightControl:
            return .maskControl
        default:
            return nil
        }
    }
}

final class EdgeSwitchLimiter {
    private let lock = NSLock()
    private var lastEdge = ""
    private var lastSentAt = Date.distantPast
    private let interval: TimeInterval = 0.08

    func shouldSend(edge: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if edge == lastEdge && now.timeIntervalSince(lastSentAt) < interval {
            return false
        }
        lastEdge = edge
        lastSentAt = now
        return true
    }

    func reset() {
        lock.lock()
        lastEdge = ""
        lastSentAt = Date.distantPast
        lock.unlock()
    }
}

final class MouseMoveCoalescer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mousebridge.helper.mousemove")
    private let flushInterval: TimeInterval = 1.0 / 240.0
    private let send: (InputPayload) -> Void
    private var timer: DispatchSourceTimer?
    private var pendingDX: Double = 0
    private var pendingDY: Double = 0
    private var pendingButton = ""

    init(send: @escaping (InputPayload) -> Void) {
        self.send = send
    }

    func enqueue(dx: Double, dy: Double, button: String?) {
        queue.async {
            let normalizedButton = button ?? ""
            if !self.pendingButton.isEmpty && self.pendingButton != normalizedButton {
                self.flushLocked()
            }
            self.pendingDX += dx
            self.pendingDY += dy
            self.pendingButton = normalizedButton
            self.ensureTimerLocked()
        }
    }

    func flush() {
        queue.async {
            self.flushLocked()
        }
    }

    func clear() {
        queue.async {
            self.pendingDX = 0
            self.pendingDY = 0
            self.pendingButton = ""
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func ensureTimerLocked() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        timer.setEventHandler { [weak self] in
            self?.flushLocked()
        }
        self.timer = timer
        timer.resume()
    }

    private func flushLocked() {
        guard pendingDX != 0 || pendingDY != 0 else { return }
        let payload = InputPayload(
            kind: "mouse_move",
            dx: pendingDX,
            dy: pendingDY,
            key_code: nil,
            modifiers: nil,
            text: nil,
            button: pendingButton.isEmpty ? nil : pendingButton,
            pressed: nil
        )
        pendingDX = 0
        pendingDY = 0
        pendingButton = ""
        send(payload)
    }
}

enum ScreenEdgeDetector {
    private static let threshold: CGFloat = 2.0

    static func detect(location: CGPoint) -> (edge: String, pct: Double)? {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let minX = bounds.minX
        let maxX = bounds.maxX
        let minY = bounds.minY
        let maxY = bounds.maxY

        switch true {
        case location.x <= minX + threshold:
            return ("left", normalized((location.y - minY) / max(bounds.height, 1)))
        case location.x >= maxX - 1 - threshold:
            return ("right", normalized((location.y - minY) / max(bounds.height, 1)))
        case location.y <= minY + threshold:
            return ("top", normalized((location.x - minX) / max(bounds.width, 1)))
        case location.y >= maxY - 1 - threshold:
            return ("bottom", normalized((location.x - minX) / max(bounds.width, 1)))
        default:
            return nil
        }
    }

    private static func normalized(_ value: CGFloat) -> Double {
        Double(min(max(value, 0), 1))
    }
}

enum Logger {
    private static let verboseInput = ProcessInfo.processInfo.environment["MB_HELPER_VERBOSE_INPUT"] == "1"

    static func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        FileHandle.standardError.write(Data("[helper] \(timestamp) \(message)\n".utf8))
    }

    static func input(_ message: String) {
        guard verboseInput else { return }
        log(message)
    }
}

enum HotkeyParser {
    static func parse(action: String, combo: String) -> ParsedHotkey? {
        let parts = combo
            .lowercased()
            .split(separator: "+")
            .map(String.init)

        guard let last = parts.last, let keyCode = keyCode(for: last) else {
            return nil
        }

        let modifiers = parts.dropLast().reduce(CGEventFlags()) { partial, token in
            partial.union(modifierFlag(for: token))
        }

        return ParsedHotkey(action: action, combo: combo, keyCode: keyCode, modifiers: modifiers)
    }

    private static func modifierFlag(for token: String) -> CGEventFlags {
        switch token {
        case "cmd", "command":
            return .maskCommand
        case "shift":
            return .maskShift
        case "alt", "option":
            return .maskAlternate
        case "ctrl", "control":
            return .maskControl
        default:
            return []
        }
    }

    private static func keyCode(for token: String) -> CGKeyCode? {
        switch token {
        case "left":
            return CGKeyCode(kVK_LeftArrow)
        case "right":
            return CGKeyCode(kVK_RightArrow)
        case "up":
            return CGKeyCode(kVK_UpArrow)
        case "down":
            return CGKeyCode(kVK_DownArrow)
        case "home":
            return CGKeyCode(kVK_Home)
        case "escape", "esc":
            return CGKeyCode(kVK_Escape)
        case "end":
            return CGKeyCode(kVK_End)
        case "space":
            return CGKeyCode(kVK_Space)
        case "return", "enter":
            return CGKeyCode(kVK_Return)
        default:
            guard token.count == 1, let scalar = token.unicodeScalars.first else {
                return nil
            }
            switch scalar {
            case "a": return 0
            case "s": return 1
            case "d": return 2
            case "f": return 3
            case "h": return 4
            case "g": return 5
            case "z": return 6
            case "x": return 7
            case "c": return 8
            case "v": return 9
            case "b": return 11
            case "q": return 12
            case "w": return 13
            case "e": return 14
            case "r": return 15
            case "y": return 16
            case "t": return 17
            case "1": return 18
            case "2": return 19
            case "3": return 20
            case "4": return 21
            case "6": return 22
            case "5": return 23
            case "=": return 24
            case "9": return 25
            case "7": return 26
            case "-": return 27
            case "8": return 28
            case "0": return 29
            case "]": return 30
            case "o": return 31
            case "u": return 32
            case "[": return 33
            case "i": return 34
            case "p": return 35
            case "l": return 37
            case "j": return 38
            case "'": return 39
            case "k": return 40
            case ";": return 41
            case "\\": return 42
            case ",": return 43
            case "/": return 44
            case "n": return 45
            case "m": return 46
            case ".": return 47
            default:
                return nil
            }
        }
    }
}

final class HotkeyRegistry {
    private var hotkeys: [ParsedHotkey] = []

    func update(from payload: ConfigPushPayload) {
        hotkeys = payload.hotkeys.compactMap { action, combo in
            guard !combo.isEmpty else { return nil }
            guard let parsed = HotkeyParser.parse(action: action, combo: combo) else {
                Logger.log("unsupported hotkey combo action=\(action) combo=\(combo)")
                return nil
            }
            return parsed
        }

        let summary = hotkeys
            .map { "\($0.action)=\($0.combo)" }
            .sorted()
            .joined(separator: ", ")
        Logger.log("loaded hotkeys: \(summary)")
    }

    func match(keyCode: CGKeyCode, flags: CGEventFlags) -> ParsedHotkey? {
        let normalized = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        return hotkeys.first { $0.keyCode == keyCode && $0.modifiers == normalized }
    }
}

final class SocketClient: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let registry: HotkeyRegistry
    private let state: HelperState
    private let readQueue = DispatchQueue(label: "mousebridge.helper.socket")
    private let writeQueue = DispatchQueue(label: "mousebridge.helper.socket.write")

    init(socketPath: String, registry: HotkeyRegistry, state: HelperState) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HelperError.socketConnectFailed(socketPath)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let utf8Path = Array(socketPath.utf8CString)
        guard utf8Path.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw HelperError.socketPathTooLong(socketPath)
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: utf8Path.count) { cStringPtr in
                _ = utf8Path.withUnsafeBufferPointer { buffer in
                    strncpy(cStringPtr, buffer.baseAddress, utf8Path.count)
                }
            }
        }

        let addrSize = socklen_t(MemoryLayout.size(ofValue: addr))
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, addrSize)
            }
        }
        guard connectResult == 0 else {
            Darwin.close(fd)
            throw HelperError.socketConnectFailed(socketPath)
        }

        self.fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.registry = registry
        self.state = state
    }

    func open() {
        // POSIX socket is already connected.
    }

    func sendRegister() throws {
        try send(type: "register", payload: RegisterPayload(pid: getpid(), name: "mousebridge-helper", version: "0.1.0"))
    }

    func startReading() {
        readQueue.async { [self] in
            var buffer = Data()
            let chunkSize = 4096
            var chunk = [UInt8](repeating: 0, count: chunkSize)

            while true {
                let count = Darwin.read(fileHandle.fileDescriptor, &chunk, chunkSize)
                if count <= 0 {
                    Logger.log("socket closed")
                    return
                }
                buffer.append(chunk, count: count)

                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.prefix(upTo: newlineIndex)
                    buffer.removeSubrange(...newlineIndex)
                    handle(line: Data(line))
                }
            }
        }
    }

    func sendHotkey(action: String, combo: String) {
        do {
            try send(type: "hotkey", payload: HotkeyPayload(action: action, combo: combo))
            Logger.log("sent hotkey action=\(action) combo=\(combo)")
        } catch {
            Logger.log("send hotkey failed: \(error)")
        }
    }

    func sendEdge(edge: String, pct: Double) {
        do {
            try send(type: "edge", payload: EdgePayload(edge: edge, pct: pct))
            Logger.log("sent edge edge=\(edge) pct=\(pct)")
        } catch {
            Logger.log("send edge failed: \(error)")
        }
    }

    func sendInput(_ payload: InputPayload) {
        do {
            try send(type: "input", payload: payload)
            Logger.input("sent input kind=\(payload.kind)")
        } catch {
            Logger.log("send input failed: \(error)")
        }
    }

    private func handle(line: Data) {
        do {
            guard let root = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = root["type"] as? String else {
                Logger.log("invalid envelope")
                return
            }

            switch type {
            case "ack":
                if let payload = root["payload"] {
                    let payloadData = try JSONSerialization.data(withJSONObject: payload)
                    let ack = try decoder.decode(AckPayload.self, from: payloadData)
                    Logger.log("daemon ack: \(ack.message ?? "ok")")
                }
            case "config_push":
                if let payload = root["payload"] {
                    let payloadData = try JSONSerialization.data(withJSONObject: payload)
                    let config = try decoder.decode(ConfigPushPayload.self, from: payloadData)
                    Logger.log("config push daemon=\(config.daemon.name) sessions=\(config.sessions.count) active_target=\(config.active_target)")
                    state.update(from: config)
                    registry.update(from: config)
                }
            case "input":
                if let payload = root["payload"] {
                    let payloadData = try JSONSerialization.data(withJSONObject: payload)
                    let input = try decoder.decode(InputPayload.self, from: payloadData)
                    try InputInjector.inject(input)
                }
            case "error":
                Logger.log("daemon protocol error")
            default:
                Logger.log("ignored message type=\(type)")
            }
        } catch {
            Logger.log("decode failed: \(error)")
        }
    }

    private func send<T: Encodable>(type: String, payload: T) throws {
        let env = Envelope(type: type, payload: payload)
        let data = try encoder.encode(env) + Data([0x0A])
        try writeQueue.sync {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    throw HelperError.writeFailed
                }
                var remaining = data.count
                var pointer = base
                while remaining > 0 {
                    let written = Darwin.write(fileHandle.fileDescriptor, pointer, remaining)
                    if written <= 0 {
                        throw HelperError.writeFailed
                    }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
            }
        }
    }
}

final class EventTapRunner {
    private let registry: HotkeyRegistry
    private let state: HelperState
    private let client: SocketClient
    private let modifierState = ModifierState()
    private let edgeLimiter = EdgeSwitchLimiter()
    private let moveCoalescer: MouseMoveCoalescer
    private var tap: CFMachPort?
    private var swallowedHotkeyKeyCodes = Set<CGKeyCode>()

    init(registry: HotkeyRegistry, state: HelperState, client: SocketClient) {
        self.registry = registry
        self.state = state
        self.client = client
        self.moveCoalescer = MouseMoveCoalescer { payload in
            client.sendInput(payload)
        }
    }

    func start() throws {
        if !AXIsProcessTrusted() {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            throw HelperError.accessibilityNotGranted
        }

        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask()) { partial, type in
            partial | (1 << type.rawValue)
        }
        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let runner = Unmanaged<EventTapRunner>.fromOpaque(userInfo).takeUnretainedValue()
            return runner.handle(proxy: proxy, type: type, event: event)
        }

        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: userInfo
        ) else {
            throw HelperError.eventTapCreateFailed
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Logger.log("event tap started")
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if InputInjector.shouldIgnore(type: type, event: event) {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let flags = event.flags
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                if let match = registry.match(keyCode: keyCode, flags: flags) {
                    swallowedHotkeyKeyCodes.insert(keyCode)
                    if match.action == "switch_to_host" {
                        state.suppressEdgeSwitching(for: 2.0)
                    }
                    client.sendHotkey(action: match.action, combo: match.combo)
                    return nil
                }
                if matchesEmergencyReturn(keyCode: keyCode, flags: flags) {
                    swallowedHotkeyKeyCodes.insert(keyCode)
                    state.suppressEdgeSwitching(for: 2.0)
                    client.sendHotkey(action: "switch_to_host", combo: emergencyReturnCombo)
                    return nil
                }
            }
        }

        if type == .keyUp, swallowedHotkeyKeyCodes.contains(keyCode) {
            swallowedHotkeyKeyCodes.remove(keyCode)
            return nil
        }

        if shouldCheckEdge(for: type) {
            let detectedEdge = ScreenEdgeDetector.detect(location: event.location)
            if state.allowEdgeSwitch(detectedEdge: detectedEdge != nil),
               let edge = detectedEdge,
               !state.edgeTarget(for: edge.edge).isEmpty,
               edgeLimiter.shouldSend(edge: edge.edge) {
                client.sendEdge(edge: edge.edge, pct: edge.pct)
            } else if detectedEdge == nil {
                edgeLimiter.reset()
            }
        } else {
            edgeLimiter.reset()
        }

        guard state.shouldForwardInput() else {
            moveCoalescer.clear()
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .mouseMoved:
            let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
            let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
            if dx != 0 || dy != 0 {
                moveCoalescer.enqueue(dx: dx, dy: dy, button: nil)
            }
            return nil
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
            let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
            if dx != 0 || dy != 0 {
                moveCoalescer.enqueue(dx: dx, dy: dy, button: buttonName(for: type, event: event))
            }
            return nil
        case .leftMouseDown:
            moveCoalescer.flush()
            client.sendInput(InputPayload(kind: "mouse_button", dx: nil, dy: nil, key_code: nil, modifiers: nil, text: nil, button: "left", pressed: true))
            return nil
        case .leftMouseUp:
            moveCoalescer.flush()
            client.sendInput(InputPayload(kind: "mouse_button", dx: nil, dy: nil, key_code: nil, modifiers: nil, text: nil, button: "left", pressed: false))
            return nil
        case .rightMouseDown:
            moveCoalescer.flush()
            client.sendInput(InputPayload(kind: "mouse_button", dx: nil, dy: nil, key_code: nil, modifiers: nil, text: nil, button: "right", pressed: true))
            return nil
        case .rightMouseUp:
            moveCoalescer.flush()
            client.sendInput(InputPayload(kind: "mouse_button", dx: nil, dy: nil, key_code: nil, modifiers: nil, text: nil, button: "right", pressed: false))
            return nil
        case .otherMouseDown:
            moveCoalescer.flush()
            client.sendInput(InputPayload(kind: "mouse_button", dx: nil, dy: nil, key_code: nil, modifiers: nil, text: nil, button: buttonName(for: type, event: event), pressed: true))
            return nil
        case .otherMouseUp:
            moveCoalescer.flush()
            client.sendInput(InputPayload(kind: "mouse_button", dx: nil, dy: nil, key_code: nil, modifiers: nil, text: nil, button: buttonName(for: type, event: event), pressed: false))
            return nil
        case .scrollWheel:
            moveCoalescer.flush()
            let dy = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let dx = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            client.sendInput(InputPayload(kind: "scroll", dx: dx, dy: dy, key_code: nil, modifiers: nil, text: nil, button: nil, pressed: nil))
            return nil
        case .flagsChanged:
            moveCoalescer.flush()
            guard let isDown = modifierState.transition(for: keyCode, flags: event.flags) else {
                return nil
            }
            client.sendInput(InputPayload(kind: isDown ? "key_down" : "key_up", dx: nil, dy: nil, key_code: Int64(keyCode), modifiers: Int64(event.flags.rawValue), text: nil, button: nil, pressed: nil))
            return nil
        case .keyDown:
            moveCoalescer.flush()
            client.sendInput(InputPayload(kind: "key_down", dx: nil, dy: nil, key_code: Int64(keyCode), modifiers: Int64(event.flags.rawValue), text: nil, button: nil, pressed: nil))
            return nil
        case .keyUp:
            moveCoalescer.flush()
            client.sendInput(InputPayload(kind: "key_up", dx: nil, dy: nil, key_code: Int64(keyCode), modifiers: Int64(event.flags.rawValue), text: nil, button: nil, pressed: nil))
            return nil
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func buttonName(for type: CGEventType, event: CGEvent) -> String {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return "left"
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return "right"
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return mouseButtonName(number: event.getIntegerValueField(.mouseEventButtonNumber))
        default:
            return ""
        }
    }

    private func mouseButtonName(number: Int64) -> String {
        switch number {
        case 2:
            return "middle"
        default:
            return "other"
        }
    }

    private func shouldCheckEdge(for type: CGEventType) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    private func matchesEmergencyReturn(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        let normalized = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        return keyCode == emergencyReturnKeyCode && normalized == emergencyReturnModifiers
    }
}

enum HelperError: Error, CustomStringConvertible {
    case configReadFailed(String)
    case socketConnectFailed(String)
    case socketPathTooLong(String)
    case writeFailed
    case accessibilityNotGranted
    case eventTapCreateFailed
    case unsupportedInput(String)
    case invalidArguments(String)
    case commandFailed(String)

    var description: String {
        switch self {
        case .configReadFailed(let path):
            return "failed to read config at \(path)"
        case .socketConnectFailed(let path):
            return "failed to connect to daemon socket at \(path)"
        case .socketPathTooLong(let path):
            return "daemon socket path too long: \(path)"
        case .writeFailed:
            return "failed to write to daemon socket"
        case .accessibilityNotGranted:
            return "Accessibility permission is not granted"
        case .eventTapCreateFailed:
            return "failed to create CGEventTap"
        case .unsupportedInput(let kind):
            return "unsupported input kind \(kind)"
        case .invalidArguments(let message):
            return "invalid arguments: \(message)"
        case .commandFailed(let message):
            return message
        }
    }
}

enum InputInjector {
    private static let guardState = InjectionGuard()
    private static let captureSuppression = CaptureSuppressionState()
    private static let syntheticMarker: Int64 = 0x4D420001

    static func signature(for input: InputPayload) -> String {
        switch input.kind {
        case "mouse_move":
            return "mouse:\(mouseMoveType(button: input.button).rawValue):\(Int64(input.dx ?? 0)):\(Int64(input.dy ?? 0)):\(normalizedButton(input.button))"
        case "mouse_button":
            return "button:\(mouseButtonType(button: input.button ?? "left", pressed: input.pressed ?? false).rawValue):\(normalizedButton(input.button))"
        case "scroll":
            return "scroll:\(Int64(input.dy ?? 0)):\(Int64(input.dx ?? 0))"
        case "key_down":
            return "key:any:\(input.key_code ?? 0)"
        case "key_up":
            return "key:any:\(input.key_code ?? 0)"
        default:
            return "kind:\(input.kind)"
        }
    }

    static func shouldIgnore(type: CGEventType, event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker {
            return true
        }
        if captureSuppression.shouldIgnore(type: type) {
            return true
        }

        let signature: String
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let button: String
            switch type {
            case .leftMouseDragged:
                button = "left"
            case .rightMouseDragged:
                button = "right"
            case .otherMouseDragged:
                button = event.getIntegerValueField(.mouseEventButtonNumber) == 2 ? "middle" : "other"
            default:
                button = ""
            }
            signature = "mouse:\(type.rawValue):\(event.getIntegerValueField(.mouseEventDeltaX)):\(event.getIntegerValueField(.mouseEventDeltaY)):\(button)"
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let button: String
            switch type {
            case .leftMouseDown, .leftMouseUp:
                button = "left"
            case .rightMouseDown, .rightMouseUp:
                button = "right"
            case .otherMouseDown, .otherMouseUp:
                button = event.getIntegerValueField(.mouseEventButtonNumber) == 2 ? "middle" : "other"
            default:
                button = ""
            }
            signature = "button:\(type.rawValue):\(button)"
        case .scrollWheel:
            signature = "scroll:\(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)):\(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))"
        case .keyDown, .keyUp, .flagsChanged:
            signature = "key:any:\(event.getIntegerValueField(.keyboardEventKeycode))"
        default:
            signature = "type:\(type.rawValue)"
        }
        return guardState.shouldIgnore(signature: signature)
    }

    static func inject(_ input: InputPayload) throws {
        guardState.record(signature(for: input))
        captureSuppression.record(for: input)
        switch input.kind {
        case "mouse_move":
            try injectMouseMove(dx: input.dx ?? 0, dy: input.dy ?? 0, button: input.button)
        case "mouse_button":
            try injectMouseButton(button: input.button ?? "left", pressed: input.pressed ?? false)
        case "scroll":
            try injectScroll(dx: input.dx ?? 0, dy: input.dy ?? 0)
        case "key_tap":
            try injectKeyTap(keyCode: input.key_code ?? 0, modifiers: input.modifiers ?? 0)
        case "key_down":
            try injectKeyEvent(kind: "key_down", keyCode: input.key_code ?? 0, modifiers: input.modifiers ?? 0)
        case "key_up":
            try injectKeyEvent(kind: "key_up", keyCode: input.key_code ?? 0, modifiers: input.modifiers ?? 0)
        case "text":
            try injectText(input.text ?? "")
        default:
            throw HelperError.unsupportedInput(input.kind)
        }
    }

    private static func injectMouseMove(dx: Double, dy: Double, button: String?) throws {
        let location = CGEvent(source: nil)?.location ?? .zero
        let next = CGPoint(x: location.x + dx, y: location.y + dy)
        let mouseType = mouseMoveType(button: button)
        let mouseButton = cgMouseButton(for: button)
        guard let event = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: next, mouseButton: mouseButton) else {
            throw HelperError.unsupportedInput("mouse_move")
        }
        markSynthetic(event)
        event.post(tap: .cghidEventTap)
        Logger.input("injected mouse_move dx=\(dx) dy=\(dy) button=\(normalizedButton(button)) from=(\(location.x),\(location.y)) to=(\(next.x),\(next.y))")
    }

    private static func injectMouseButton(button: String, pressed: Bool) throws {
        let location = CGEvent(source: nil)?.location ?? .zero
        let mouseButton = cgMouseButton(for: button)
        let mouseType = mouseButtonType(button: button, pressed: pressed)

        guard let event = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: location, mouseButton: mouseButton) else {
            throw HelperError.unsupportedInput("mouse_button")
        }
        markSynthetic(event)
        event.post(tap: .cghidEventTap)
        Logger.input("injected mouse_button button=\(button) pressed=\(pressed)")
    }

    private static func injectScroll(dx: Double, dy: Double) throws {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
            throw HelperError.unsupportedInput("scroll")
        }
        markSynthetic(event)
        event.post(tap: .cghidEventTap)
        Logger.input("injected scroll dx=\(dx) dy=\(dy)")
    }

    private static func injectKeyTap(keyCode: Int64, modifiers: Int64) throws {
        try injectKeyEvent(kind: "key_down", keyCode: keyCode, modifiers: modifiers)
        try injectKeyEvent(kind: "key_up", keyCode: keyCode, modifiers: modifiers)
        Logger.input("injected key_tap key_code=\(keyCode) modifiers=\(modifiers)")
    }

    private static func injectText(_ text: String) throws {
        for character in text {
            let units = Array(String(character).utf16)
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw HelperError.unsupportedInput("text")
            }
            var mutableUnits = units
            keyDown.keyboardSetUnicodeString(stringLength: mutableUnits.count, unicodeString: &mutableUnits)
            keyUp.keyboardSetUnicodeString(stringLength: mutableUnits.count, unicodeString: &mutableUnits)
            markSynthetic(keyDown)
            markSynthetic(keyUp)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        Logger.input("injected text len=\(text.count)")
    }

    private static func injectKeyEvent(kind: String, keyCode: Int64, modifiers: Int64) throws {
        let isDown: Bool
        switch kind {
        case "key_down":
            isDown = true
        case "key_up":
            isDown = false
        default:
            throw HelperError.unsupportedInput(kind)
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            throw HelperError.unsupportedInput(kind)
        }
        let flags = CGEventFlags(rawValue: UInt64(modifiers))
        let event = isDown ? keyDown : keyUp
        event.flags = flags
        markSynthetic(event)
        event.post(tap: .cghidEventTap)
        Logger.input("injected \(kind) key_code=\(keyCode) modifiers=\(modifiers)")
    }

    private static func mouseMoveType(button: String?) -> CGEventType {
        switch normalizedButton(button) {
        case "left":
            return .leftMouseDragged
        case "right":
            return .rightMouseDragged
        case "middle", "other":
            return .otherMouseDragged
        default:
            return .mouseMoved
        }
    }

    private static func mouseButtonType(button: String, pressed: Bool) -> CGEventType {
        switch (normalizedButton(button), pressed) {
        case ("left", true):
            return .leftMouseDown
        case ("left", false):
            return .leftMouseUp
        case ("right", true):
            return .rightMouseDown
        case ("right", false):
            return .rightMouseUp
        case ("middle", true), ("other", true):
            return .otherMouseDown
        case ("middle", false), ("other", false):
            return .otherMouseUp
        default:
            return pressed ? .leftMouseDown : .leftMouseUp
        }
    }

    private static func cgMouseButton(for button: String?) -> CGMouseButton {
        switch normalizedButton(button) {
        case "right":
            return .right
        case "middle", "other":
            return CGMouseButton(rawValue: 2) ?? .left
        default:
            return .left
        }
    }

    private static func normalizedButton(_ button: String?) -> String {
        switch button?.lowercased() {
        case "left":
            return "left"
        case "right":
            return "right"
        case "middle":
            return "middle"
        case "other":
            return "other"
        default:
            return ""
        }
    }

    private static func markSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
    }
}

enum HelperCommand {
    case run(dataDir: String)
    case printLaunchAgent(dataDir: String, label: String, program: String)
    case installLaunchAgent(dataDir: String, label: String, program: String)
    case uninstallLaunchAgent(label: String)
    case openAccessibility
    case checkAccessibility
    case help
}

func runHelper(dataDir: String) throws {
    let configPath = URL(fileURLWithPath: dataDir).appendingPathComponent("config.json").path
    let config = try loadConfig(path: configPath)
    let socketPath = helperSocketPath(dataDir: dataDir, port: config.port)

    Logger.log("starting data_dir=\(dataDir) socket=\(socketPath)")

    let registry = HotkeyRegistry()
    let state = HelperState()
    let client = try SocketClient(socketPath: socketPath, registry: registry, state: state)
    client.open()
    try client.sendRegister()
    client.startReading()

    let eventTap = EventTapRunner(registry: registry, state: state, client: client)
    try eventTap.start()

    Logger.log("helper running")
    CFRunLoopRun()
}

func parseCommand() throws -> HelperCommand {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || args.first?.hasPrefix("--") == true {
        return .run(dataDir: try parseDataDir(from: args))
    }

    switch args[0] {
    case "run":
        return .run(dataDir: try parseDataDir(from: Array(args.dropFirst())))
    case "print-launch-agent":
        let tail = Array(args.dropFirst())
        let dataDir = try parseDataDir(from: tail)
        return .printLaunchAgent(
            dataDir: dataDir,
            label: parseLabel(from: tail, dataDir: dataDir),
            program: try parseProgramPath(from: tail)
        )
    case "install-launch-agent":
        let tail = Array(args.dropFirst())
        let dataDir = try parseDataDir(from: tail)
        return .installLaunchAgent(
            dataDir: dataDir,
            label: parseLabel(from: tail, dataDir: dataDir),
            program: try parseProgramPath(from: tail)
        )
    case "uninstall-launch-agent":
        let tail = Array(args.dropFirst())
        let dataDir = try parseDataDir(from: tail)
        return .uninstallLaunchAgent(label: parseLabel(from: tail, dataDir: dataDir))
    case "open-accessibility":
        return .openAccessibility
    case "check-accessibility":
        return .checkAccessibility
    case "help", "--help", "-h":
        return .help
    default:
        throw HelperError.invalidArguments("unknown command \(args[0])")
    }
}

func parseDataDir(from args: [String]) throws -> String {
    if let index = args.firstIndex(of: "--data-dir") {
        guard index + 1 < args.count else {
            throw HelperError.invalidArguments("missing value for --data-dir")
        }
        return resolvePath(args[index + 1])
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.mousebridge"
}

func parseLabel(from args: [String], dataDir: String) -> String {
    if let index = args.firstIndex(of: "--label"), index + 1 < args.count {
        return args[index + 1]
    }
    return defaultLaunchAgentLabel(dataDir: dataDir)
}

func parseProgramPath(from args: [String]) throws -> String {
    if let index = args.firstIndex(of: "--program") {
        guard index + 1 < args.count else {
            throw HelperError.invalidArguments("missing value for --program")
        }
        return resolvePath(args[index + 1])
    }
    return try currentExecutablePath()
}

func resolvePath(_ value: String) -> String {
    if value.hasPrefix("/") {
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }
    return URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
}

func currentExecutablePath() throws -> String {
    guard let executable = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first else {
        throw HelperError.invalidArguments("unable to determine helper executable path")
    }
    return resolvePath(executable)
}

func defaultLaunchAgentLabel(dataDir: String) -> String {
    let digest = SHA256.hash(data: Data(dataDir.utf8))
    let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    return "com.mousebridge.helper.\(suffix)"
}

func launchAgentPlistPath(label: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/Library/LaunchAgents/\(label).plist"
}

func helperLogPath(dataDir: String, fileName: String) -> String {
    return URL(fileURLWithPath: dataDir).appendingPathComponent("logs").appendingPathComponent(fileName).path
}

func xmlEscaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

func launchAgentPlist(label: String, program: String, dataDir: String) -> String {
    let workingDirectory = URL(fileURLWithPath: program).deletingLastPathComponent().path
    let stdoutPath = helperLogPath(dataDir: dataDir, fileName: "helper.stdout.log")
    let stderrPath = helperLogPath(dataDir: dataDir, fileName: "helper.stderr.log")
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>\(xmlEscaped(label))</string>
      <key>LimitLoadToSessionType</key>
      <array>
        <string>Aqua</string>
      </array>
      <key>ProgramArguments</key>
      <array>
        <string>\(xmlEscaped(program))</string>
        <string>run</string>
        <string>--data-dir</string>
        <string>\(xmlEscaped(dataDir))</string>
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <true/>
      <key>ProcessType</key>
      <string>Interactive</string>
      <key>WorkingDirectory</key>
      <string>\(xmlEscaped(workingDirectory))</string>
      <key>StandardOutPath</key>
      <string>\(xmlEscaped(stdoutPath))</string>
      <key>StandardErrorPath</key>
      <string>\(xmlEscaped(stderrPath))</string>
    </dict>
    </plist>
    """
}

@discardableResult
func runCommand(_ launchPath: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if process.terminationStatus != 0 && !allowFailure {
        throw HelperError.commandFailed("\(launchPath) \(arguments.joined(separator: " ")): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return output
}

func installLaunchAgent(label: String, program: String, dataDir: String) throws {
    let plistPath = launchAgentPlistPath(label: label)
    let fileManager = FileManager.default
    try fileManager.createDirectory(atPath: URL(fileURLWithPath: plistPath).deletingLastPathComponent().path, withIntermediateDirectories: true)
    try fileManager.createDirectory(atPath: URL(fileURLWithPath: helperLogPath(dataDir: dataDir, fileName: "helper.stderr.log")).deletingLastPathComponent().path, withIntermediateDirectories: true)
    try launchAgentPlist(label: label, program: program, dataDir: dataDir).write(toFile: plistPath, atomically: true, encoding: .utf8)

    let domain = "gui/\(getuid())"
    _ = try runCommand("/bin/launchctl", ["bootout", domain, plistPath], allowFailure: true)
    try runCommand("/bin/launchctl", ["bootstrap", domain, plistPath])
    _ = try runCommand("/bin/launchctl", ["enable", "\(domain)/\(label)"], allowFailure: true)
    try runCommand("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(label)"])

    print("installed LaunchAgent \(label)")
    print("plist: \(plistPath)")
    print("logs: \(URL(fileURLWithPath: helperLogPath(dataDir: dataDir, fileName: "helper.stderr.log")).deletingLastPathComponent().path)")
}

func uninstallLaunchAgent(label: String) throws {
    let plistPath = launchAgentPlistPath(label: label)
    let domain = "gui/\(getuid())"
    _ = try runCommand("/bin/launchctl", ["bootout", domain, plistPath], allowFailure: true)
    if FileManager.default.fileExists(atPath: plistPath) {
        try FileManager.default.removeItem(atPath: plistPath)
    }
    print("uninstalled LaunchAgent \(label)")
}

func openAccessibilitySettings() throws {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
        throw HelperError.invalidArguments("failed to build Accessibility settings URL")
    }
    if !NSWorkspace.shared.open(url) {
        throw HelperError.commandFailed("failed to open Accessibility settings")
    }
}

func printUsage() {
    print("""
    MouseBridge Helper

    Usage:
      mousebridge-helper run [--data-dir DIR]
      mousebridge-helper --data-dir DIR
      mousebridge-helper print-launch-agent [--data-dir DIR] [--label LABEL] [--program PATH]
      mousebridge-helper install-launch-agent [--data-dir DIR] [--label LABEL] [--program PATH]
      mousebridge-helper uninstall-launch-agent [--data-dir DIR] [--label LABEL]
      mousebridge-helper check-accessibility
      mousebridge-helper open-accessibility

    Notes:
      - install-launch-agent creates a per-data-dir LaunchAgent with RunAtLoad + KeepAlive.
      - open-accessibility opens the macOS Accessibility settings pane.
      - set MB_HELPER_VERBOSE_INPUT=1 to enable per-input helper logs.
    """)
}

func loadConfig(path: String) throws -> ConfigFile {
    guard let data = FileManager.default.contents(atPath: path) else {
        throw HelperError.configReadFailed(path)
    }
    return try JSONDecoder().decode(ConfigFile.self, from: data)
}

func helperSocketPath(dataDir: String, port: Int) -> String {
    let digest = SHA256.hash(data: Data(dataDir.utf8))
    let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    return "\(NSTemporaryDirectory())mb-helper-\(port)-\(suffix).sock"
}

do {
    switch try parseCommand() {
    case .run(let dataDir):
        try runHelper(dataDir: dataDir)
    case .printLaunchAgent(let dataDir, let label, let program):
        print(launchAgentPlist(label: label, program: program, dataDir: dataDir))
    case .installLaunchAgent(let dataDir, let label, let program):
        try installLaunchAgent(label: label, program: program, dataDir: dataDir)
    case .uninstallLaunchAgent(let label):
        try uninstallLaunchAgent(label: label)
    case .openAccessibility:
        try openAccessibilitySettings()
    case .checkAccessibility:
        if AXIsProcessTrusted() {
            print("Accessibility permission: granted")
        } else {
            print("Accessibility permission: not granted")
            exit(1)
        }
    case .help:
        printUsage()
    }
} catch {
    Logger.log("fatal: \(error)")
    exit(1)
}
