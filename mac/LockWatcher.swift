// LockWatcher — macOS side of omarchy-continuity.
//
// Listens for the screen lock / unlock notifications macOS posts and forwards
// them to the Omarchy machine over SSH (key restricted to the lock daemon).
// While this Mac is unlocked it also sends an "awake" heartbeat once a minute,
// which keeps the Omarchy machine from idle-locking while you work over here.
// The heartbeat expires on the Omarchy side by itself when the cable is out.
//
// Configured through environment variables set in the LaunchAgent plist:
//   OC_HOST         Omarchy machine address on the Thunderbolt bridge (169.254.99.1)
//   OC_USER         user on the Omarchy machine
//   OC_KEY          private key path (default ~/.ssh/omarchy-continuity)
//   OC_SYNC_LOCK    "1" to lock Omarchy when this Mac locks (default 1)
//   OC_SYNC_UNLOCK  "1" to unlock Omarchy when this Mac unlocks (default 1)
//   OC_KEEP_AWAKE   "1" to keep Omarchy awake while this Mac is unlocked (default 1)
import CoreGraphics
import Foundation

let env = ProcessInfo.processInfo.environment
let host = env["OC_HOST"] ?? "169.254.99.1"
let user = env["OC_USER"] ?? NSUserName()
let key = env["OC_KEY"] ?? (NSHomeDirectory() + "/.ssh/omarchy-continuity")
let syncLock = (env["OC_SYNC_LOCK"] ?? "1") == "1"
let syncUnlock = (env["OC_SYNC_UNLOCK"] ?? "1") == "1"
let keepAwake = (env["OC_KEEP_AWAKE"] ?? "1") == "1"

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

func session() -> [String: Any] {
    return (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:]
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
// account to send tabs and lock requests to.
let awake = "awake " + NSUserName()

let center = DistributedNotificationCenter.default()
center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { _ in
    if onConsole() && syncLock { send("lock") }
}
center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { _ in
    guard onConsole() else { return }
    if syncUnlock { send("unlock") }
    if keepAwake { send(awake, quiet: true) }
}

if keepAwake {
    // Heartbeat: once a minute while unlocked and at the console. The Omarchy
    // side drops the hold after ~2.5 minutes without one, so a pulled cable, a
    // sleeping Mac or a switched-away account never leaves it held forever.
    let timer = Timer(timeInterval: 60, repeats: true) { _ in
        if onConsole() && !screenIsLocked() { send(awake, quiet: true) }
    }
    RunLoop.main.add(timer, forMode: .common)
    if onConsole() && !screenIsLocked() { send(awake, quiet: true) }
}

NSLog("omarchy-continuity: watching lock state, target %@@%@ (lock=%d unlock=%d keepAwake=%d)",
      user, host, syncLock ? 1 : 0, syncUnlock ? 1 : 0, keepAwake ? 1 : 0)
RunLoop.main.run()
