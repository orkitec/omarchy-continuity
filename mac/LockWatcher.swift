// LockWatcher — macOS side of omarchy-continuity.
//
// Listens for the screen lock / unlock notifications macOS posts and forwards
// them to the Omarchy machine over SSH (key restricted to the lock daemon).
// Configured through environment variables set in the LaunchAgent plist:
//   OC_HOST         Omarchy machine address on the Thunderbolt bridge (169.254.99.1)
//   OC_USER         user on the Omarchy machine
//   OC_KEY          private key path (default ~/.ssh/omarchy-continuity)
//   OC_SYNC_LOCK    "1" to lock Omarchy when this Mac locks (default 1)
//   OC_SYNC_UNLOCK  "1" to unlock Omarchy when this Mac unlocks (default 1)
import Foundation

let env = ProcessInfo.processInfo.environment
let host = env["OC_HOST"] ?? "169.254.99.1"
let user = env["OC_USER"] ?? NSUserName()
let key = env["OC_KEY"] ?? (NSHomeDirectory() + "/.ssh/omarchy-continuity")
let syncLock = (env["OC_SYNC_LOCK"] ?? "1") == "1"
let syncUnlock = (env["OC_SYNC_UNLOCK"] ?? "1") == "1"

let queue = DispatchQueue(label: "omarchy-continuity.send")

func send(_ command: String) {
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
            NSLog("omarchy-continuity: %@ -> exit %d %@", command, p.terminationStatus, reply)
        } catch {
            NSLog("omarchy-continuity: %@ failed to start ssh: %@", command, error.localizedDescription)
        }
    }
}

let center = DistributedNotificationCenter.default()
center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { _ in
    if syncLock { send("lock") }
}
center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { _ in
    if syncUnlock { send("unlock") }
}

NSLog("omarchy-continuity: watching lock state, target %@@%@ (lock=%d unlock=%d)", user, host, syncLock ? 1 : 0, syncUnlock ? 1 : 0)
RunLoop.main.run()
