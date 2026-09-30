// LockWatcher — macOS side of omarchy-continuity.
//
// Listens for the screen lock / unlock notifications macOS posts and forwards
// them to the Omarchy machine over SSH (key restricted to the lock daemon).
// While this Mac is unlocked it also sends an "awake" heartbeat once a minute,
// which keeps the Omarchy machine from idle-locking while you work over here.
// The heartbeat expires on the Omarchy side by itself when the cable is out.
//
// It also watches the pasteboard (changeCount, polled twice a second, the way
// clipboard managers do) and pipes each new text or image to the Omarchy
// machine's `clip` verb. Deskflow's Wayland clipboard path is unreliable and
// abandoned upstream, so the clipboard rides this link in both directions.
//
// Configured through environment variables set in the LaunchAgent plist:
//   OC_HOST         Omarchy machine address on the Thunderbolt bridge (169.254.99.1)
//   OC_USER         user on the Omarchy machine
//   OC_KEY          private key path (default ~/.ssh/omarchy-continuity)
//   OC_SYNC_LOCK    "1" to lock Omarchy when this Mac locks (default 1)
//   OC_SYNC_UNLOCK  "1" to unlock Omarchy when this Mac unlocks (default 1)
//   OC_KEEP_AWAKE   "1" to keep Omarchy awake while this Mac is unlocked (default 1)
//   OC_SYNC_CLIPBOARD "1" to send this Mac's clipboard to Omarchy as it changes (default 1)
//   OC_CLIP_MAX_BYTES largest clipboard payload to send (default 8 MiB)
//   OC_MANAGE_DESKFLOW "1" to run Deskflow only in the account at the console (default 1)
//   OC_DESKFLOW_APP   Deskflow app bundle (default /Applications/Deskflow.app)
import AppKit
import CoreGraphics
import CryptoKit
import Foundation

let env = ProcessInfo.processInfo.environment
let host = env["OC_HOST"] ?? "169.254.99.1"
let user = env["OC_USER"] ?? NSUserName()
let key = env["OC_KEY"] ?? (NSHomeDirectory() + "/.ssh/omarchy-continuity")
let syncLock = (env["OC_SYNC_LOCK"] ?? "1") == "1"
let syncUnlock = (env["OC_SYNC_UNLOCK"] ?? "1") == "1"
let keepAwake = (env["OC_KEEP_AWAKE"] ?? "1") == "1"
let syncClipboard = (env["OC_SYNC_CLIPBOARD"] ?? "1") == "1"
let clipMaxBytes = Int(env["OC_CLIP_MAX_BYTES"] ?? "") ?? 8 * 1024 * 1024
let manageDeskflow = (env["OC_MANAGE_DESKFLOW"] ?? "1") == "1"
let deskflowApp = env["OC_DESKFLOW_APP"] ?? "/Applications/Deskflow.app"
let stateDir = NSHomeDirectory() + "/Library/Application Support/omarchy-continuity/state"

let queue = DispatchQueue(label: "omarchy-continuity.send")

func send(_ command: String, quiet: Bool = false) {
    queue.async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-i", key,
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "ConnectTimeout=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "\(user)@\(host)", command,
        ]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do {
            try p.run()
            p.waitUntilExit()
            let reply = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !quiet || p.terminationStatus != 0 {
                NSLog("omarchy-continuity: %@ -> exit %d %@", command, p.terminationStatus, reply)
            }
        } catch {
            NSLog("omarchy-continuity: %@ failed to start ssh: %@", command, error.localizedDescription)
        }
    }
}

// Clipboard: the `clip` verb on either side records the SHA-256 of what it received and
// the sender records what it last sent, so a change matching either is an echo, not a copy.
func sha256Hex(_ data: Data) -> String {
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func readState(_ name: String) -> String {
    return (try? String(contentsOfFile: stateDir + "/" + name, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func writeState(_ name: String, _ value: String) {
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    try? value.write(toFile: stateDir + "/" + name, atomically: true, encoding: .utf8)
}

func sendClipboard(_ mime: String, _ data: Data, hash: String) {
    queue.async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-i", key,
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "ConnectTimeout=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "\(user)@\(host)", "clip \(mime)",
        ]
        let input = Pipe()
        let out = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = out
        do {
            try p.run()
        } catch {
            NSLog("omarchy-continuity: clip failed to start ssh: %@", error.localizedDescription)
            return
        }
        // Feed stdin off the main path: a pipe holds 64 KB and ssh may not drain it
        // until it has connected.
        DispatchQueue.global().async {
            input.fileHandleForWriting.write(data)
            try? input.fileHandleForWriting.close()
        }
        p.waitUntilExit()
        let reply = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if p.terminationStatus == 0 {
            writeState("clip-out.sha", hash)
            if readState("clip-fail") != "" {
                writeState("clip-fail", "")
                NSLog("omarchy-continuity: clipboard to Omarchy working again")
            }
        } else if readState("clip-fail") == "" {
            // One line per outage (cable out, Omarchy asleep), not one per copy.
            writeState("clip-fail", "1")
            NSLog("omarchy-continuity: clip %@ (%d bytes) -> exit %d %@", mime, data.count, p.terminationStatus, reply)
        }
    }
}

// What to send for the current pasteboard: text when there is any, else a PNG (screenshots),
// nothing for files or other types.
func clipboardPayload(_ pb: NSPasteboard) -> (String, Data)? {
    let types = pb.types ?? []
    if types.contains(.fileURL) { return nil }
    if let s = pb.string(forType: .string), !s.isEmpty, let d = s.data(using: .utf8) {
        return ("text/plain", d)
    }
    if let png = pb.data(forType: .png) { return ("image/png", png) }
    if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        return ("image/png", png)
    }
    return nil
}

func session() -> [String: Any] {
    return (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:]
}

// Deskflow hand-over between Mac accounts (fast user switching). Only this account's
// processes are touched; a screen lock in the same account leaves Deskflow running,
// so the password can still be typed on the lock screen from the shared keyboard.
func runQuiet(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func startDeskflow() {
    let uid = String(getuid())
    if runQuiet("/usr/bin/pgrep", ["-U", uid, "-x", "Deskflow"]) == 0 { return }
    // -g: don't bring it to the front, -j: launch hidden.
    let rc = runQuiet("/usr/bin/open", ["-g", "-j", "-a", deskflowApp])
    NSLog("omarchy-continuity: account became active, started Deskflow (open exit %d)", rc)
}

func stopDeskflow() {
    let uid = String(getuid())
    let gui = runQuiet("/usr/bin/pkill", ["-U", uid, "-x", "Deskflow"])
    let core = runQuiet("/usr/bin/pkill", ["-U", uid, "-x", "deskflow-core"])
    if gui == 0 || core == 0 {
        NSLog("omarchy-continuity: account switched away, stopped Deskflow so the active account gets the connection")
    }
}

func screenIsLocked() -> Bool {
    return (session()["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

// With several accounts logged in (fast user switching), every account's watcher
// runs. Only the one whose session owns the display may speak for the Mac.
func onConsole() -> Bool {
    return (session()[kCGSessionOnConsoleKey as String] as? Bool) ?? true
}

// The heartbeat names this account so the Omarchy side knows which Mac
// account to send tabs and lock requests to, and carries this Mac's Wi-Fi
// address so Omarchy can wake it with a magic packet when it sleeps (the
// address is per-network and private, so it is reported rather than configured).
func wifiAddress() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "dev=$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}'); [ -n \"$dev\" ] && ifconfig \"$dev\" | awk '/ether/{print $2}'"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    p.waitUntilExit()
    let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return s.range(of: "^([0-9a-f]{2}:){5}[0-9a-f]{2}$", options: .regularExpression) != nil ? s : ""
}

func awakeCommand() -> String {
    let mac = wifiAddress()
    return "awake " + NSUserName() + (mac.isEmpty ? "" : " " + mac)
}

let center = DistributedNotificationCenter.default()
center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { _ in
    if onConsole() && syncLock { send("lock") }
}
center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { _ in
    guard onConsole() else { return }
    if syncUnlock { send("unlock") }
    if keepAwake { send(awakeCommand(), quiet: true) }
}

// Fast user switching: the account that leaves the console sends the lock (its screen
// locks), but the account that arrives gets no unlock notification, because its own
// screen was never locked. Treat becoming the console session like an unlock.
let workspace = NSWorkspace.shared.notificationCenter
workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: nil) { _ in
    if manageDeskflow { startDeskflow() }
    guard onConsole(), !screenIsLocked() else { return }
    if syncUnlock { send("unlock") }
    if keepAwake { send(awakeCommand(), quiet: true) }
}
// The Omarchy Deskflow server has one slot for the Mac. A client left running in an
// account you switched away from holds it, so the account in front gets refused
// ("already connected") and a background session can't take input anyway.
workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: nil) { _ in
    if manageDeskflow { stopDeskflow() }
}
if manageDeskflow {
    if onConsole() { startDeskflow() } else { stopDeskflow() }
}

if keepAwake {
    // Heartbeat: once a minute while unlocked and at the console. The Omarchy
    // side drops the hold after ~2.5 minutes without one, so a pulled cable, a
    // sleeping Mac or a switched-away account never leaves it held forever.
    let timer = Timer(timeInterval: 60, repeats: true) { _ in
        if onConsole() && !screenIsLocked() { send(awakeCommand(), quiet: true) }
    }
    RunLoop.main.add(timer, forMode: .common)
    if onConsole() && !screenIsLocked() { send(awakeCommand(), quiet: true) }
}

if syncClipboard {
    let pasteboard = NSPasteboard.general
    var lastChange = pasteboard.changeCount
    let clipTimer = Timer(timeInterval: 0.5, repeats: true) { _ in
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        guard onConsole() else { return }
        guard let payload = clipboardPayload(pasteboard) else { return }
        let (mime, data) = payload
        if data.count > clipMaxBytes {
            NSLog("omarchy-continuity: clipboard not sent, %d bytes exceeds OC_CLIP_MAX_BYTES", data.count)
            return
        }
        let hash = sha256Hex(data)
        if hash == readState("clip-in.sha") || hash == readState("clip-out.sha") { return }
        sendClipboard(mime, data, hash: hash)
    }
    RunLoop.main.add(clipTimer, forMode: .common)
}

NSLog("omarchy-continuity: watching lock state, target %@@%@ (lock=%d unlock=%d keepAwake=%d clipboard=%d)",
      user, host, syncLock ? 1 : 0, syncUnlock ? 1 : 0, keepAwake ? 1 : 0, syncClipboard ? 1 : 0)
RunLoop.main.run()
