# omarchy-continuity

Small glue for using an [Omarchy](https://omarchy.org) machine and a Mac side by side
over a Thunderbolt cable: one keyboard and mouse, a shared clipboard, lock state that
follows you, and "send this tab to the other machine" in the browser. Everything is
local, rides on the cable, and comes back on its own when the cable is plugged in again.

| Piece | What does it | Where |
|---|---|---|
| Keyboard, mouse | [Deskflow](https://github.com/deskflow/deskflow), Omarchy as server | notes below |
| Clipboard, both directions | this repo: clipboard watchers + `clip` verb over SSH | `linux/`, `mac/` |
| Network between the machines | Thunderbolt bridge, link-local addresses | notes below |
| Lock / unlock sync | this repo: macOS lock watcher + SSH forced command on Omarchy | `mac/`, `linux/` |
| Tab hand-off, both directions | this repo: browser extension + native host + `open` verb | `extension/`, `native/` |

## How the pieces talk

Each machine accepts SSH from the other with one dedicated key. That key is
restricted in `authorized_keys` to a single forced command (`omarchy-continuityd`),
to link-local source addresses (the Thunderbolt bridge), and to no shell, forwarding,
or agent. The forced command understands a handful of verbs and nothing else:

| Verb | Omarchy side | Mac side |
|---|---|---|
| `lock` | lock the screen | display sleep (locks when "require password" is on) |
| `unlock` | unlock the screen (opt-in, see below) | not available |
| `awake [account] [wifi-mac]` | heartbeat: hold off the idle lock while the Mac is unlocked; learns the Mac's Wi-Fi address | not available |
| `open <http(s) url>` | open in the default browser | open in the default browser |
| `clip [mime]` | stdin becomes the clipboard (`text/plain`, `image/png`) | same, via `pbcopy` / PNG on the pasteboard |
| `status` | lock screen state as JSON | `locked` / `unlocked` |

Omarchy additionally admits SSH only on the Thunderbolt interface (ufw). On the Mac,
Remote Login must be on; the key restriction and `from=` clause carry the security there.

## Lock / unlock sync

When the Mac locks, Omarchy locks. When the Mac unlocks (password, Touch ID, Apple
Watch), Omarchy unlocks. When Omarchy locks, the Mac's display sleeps and locks.
Nothing unlocks the Mac: macOS does not unlock itself programmatically.

- `mac/LockWatcher.swift` runs as a LaunchAgent, subscribes to the
  `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` notifications and runs
  `ssh omarchy lock|unlock`.
- On Omarchy, `omarchy-continuityd` locks with `omarchy-system-lock` and unlocks with
  `omarchy-shell lock unlock`. That IPC is provided by the
  [omarchy-face-unlock](https://github.com/orkitec/omarchy-face-unlock) lock screen and
  is off unless `~/.config/omarchy/face-unlock/ipc-unlock` exists. The stock Omarchy
  lock screen has no unlock IPC; locking still works without it.

Whoever can unlock the Mac can unlock the Omarchy machine. That is the point.

### No idle lock while you work on the Mac

While the cursor is on the Mac, the Omarchy machine sees no input and would idle-lock
after its usual timeout, even though you're sitting right there. So the Mac sends an
`awake` heartbeat once a minute while it is unlocked. Omarchy answers by setting its own
"stay awake" toggle (the same one as `omarchy toggle idle stay-awake`) and remembers
that it did so. A user timer checks every minute: no heartbeat for about 2.5 minutes,
because the cable is out, the Mac is asleep or locked, and the toggle is released
again. A stay-awake you set yourself is never touched. If the toggle is switched off
while the Mac is unlocked, the next heartbeat switches it back on: to let Omarchy idle
while the Mac stays unlocked, lock the Mac or unplug the cable instead. Locking the Mac
releases the hold immediately and locks Omarchy.

### Several accounts on the Mac

Each Mac account runs its own lock watcher with its own key: run `mac/install.sh` in
every account, authorize each printed key on Omarchy with `linux/install.sh`, and run
`mac/install.sh --authorize` in every account so Omarchy can reach each of them. With
fast user switching, only the account that owns the display sends anything; its
heartbeat carries the account name, and Omarchy sends tabs and lock requests to
whichever account was last seen at the console. Switching accounts locks Omarchy (the
leaving account's screen locks) and the arriving account unlocks it as soon as it owns
the console; should that message be lost, its first heartbeat unlocks a screen the Mac
locked. A lock you did on Omarchy yourself is never undone by a heartbeat.

## Clipboard

Deskflow's clipboard sharing is switched off (`clipboardSharing = false` in the server
config) and the clipboard rides the SSH link instead, in both directions:

- On Omarchy, `omarchy-continuity-clip-watch` (a user service) runs `wl-paste --watch` for
  text and PNG. Every copy is piped to the Mac's `clip` verb, which runs `pbcopy` or puts
  the PNG on the pasteboard.
- On the Mac, the lock watcher polls the pasteboard's change count twice a second, the way
  clipboard managers do, and pipes text or a PNG (screenshots; TIFF is converted) to
  Omarchy's `clip` verb, which runs `wl-copy`.
- Both `clip` verbs record the SHA-256 of what they received and each sender records what it
  last sent; a change matching either hash is an echo and is not sent again. Payloads are
  capped at 8 MiB (`OC_CLIP_MAX_BYTES`), files and other formats do not travel, and the
  Mac side can be turned off with `OC_SYNC_CLIPBOARD=0` in the LaunchAgent.

Why not Deskflow: its Wayland clipboard backend (1.26.0) only notices a change when the
set of MIME types changes, so copying text after text is never seen; it passes the payload
as a command-line argument, so anything over 128 KB fails and leaves the clipboard empty;
it mangles images; and upstream has removed the backend, with the replacement needing a
portal interface Hyprland does not provide.

## Waking the Mac from Omarchy

A sleeping Mac drops the Thunderbolt link, so the shared keyboard and mouse cannot reach
it and the Deskflow client is gone. `omarchy-continuity-wake-mac` sends a Wake-on-LAN
magic packet over the Wi-Fi both machines share; the Mac comes up on its lock screen,
Deskflow reconnects within a few seconds, and the password can be typed from the shared
keyboard. Bind it to a key, for example in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + M", "Wake the Mac", "omarchy-continuity-wake-mac")
```

Requirements on the Mac: System Settings > Battery > Options > "Wake for network access"
(by default only on the power adapter; choose Always for battery too). The Mac's Wi-Fi
address is a per-network private address, so the heartbeat reports it and Omarchy keeps
it in `~/.config/omarchy-continuity/mac-wifi`; `omarchy-continuity-wake-mac --learn` fills
it from the network while the Mac is awake. Nothing unlocks the Mac itself: macOS has no
programmatic unlock, and typing the password over Deskflow is the intended step.

For a Mac that stays on the desk plugged in, "Prevent automatic sleeping on power adapter
when the display is off" avoids the problem entirely: the display sleeps, the machine and
its Deskflow client stay up, and entering its screen wakes the display.

## Tab hand-off

The `extension/` folder is a small Manifest V3 extension for Chrome and Chromium.
It adds to the page context menu "Open this page on the other machine" and "Move this
tab to the other machine" (move closes the tab here once the other side confirmed),
"Open link on the other machine" on links, a toolbar button (move), and shortcuts
Alt+Shift+O / Alt+Shift+M. Only http(s) URLs travel; login state and form contents
don't.

It talks to `native/omarchy-continuity-native`, a native messaging host that runs
`ssh <peer> open <url>`. The peer is read from a two-line config file written by the
install scripts. The extension embeds a fixed key so its ID (`extension/ID`) is the
same on every machine, which the native host manifests require. Load it unpacked from
`chrome://extensions` with Developer mode on. Chrome shows a "developer mode
extensions" notice at startup for unpacked extensions; Chromium doesn't.

## Install

Get the repo onto both machines (clone it, or copy it over the cable). Then:

1. On the Mac (needs the Xcode Command Line Tools for `swiftc`):
   `mac/install.sh 169.254.99.1 <omarchy-user>` — builds the lock watcher, creates the
   Mac's key, installs the native host and LaunchAgent, prints the Mac's public key.
2. On Omarchy: `linux/install.sh '<that public key>'` — authorizes it, creates Omarchy's
   key, installs the native host for Chromium and Chrome, enables key-only sshd on the
   Thunderbolt interface (asks for sudo once), prints Omarchy's public key.
3. On the Mac: `mac/install.sh --authorize '<that public key>'` — authorizes it and turns
   on Remote Login (asks for sudo once).
4. Load `extension/` unpacked in Chrome (Mac) and Chromium (Omarchy).

Test from either side: `ssh -i ~/.ssh/omarchy-continuity <user>@<other> status`, and the
clipboard with `echo hi | ssh -i ~/.ssh/omarchy-continuity <user>@<other> clip`.
Logs: `journalctl -t omarchy-continuity` on Omarchy, `~/Library/Logs/omarchy-continuity.log`
on the Mac.

## Coming and going

The Mac can be unplugged and taken away at any time. When the cable comes back:

- the Thunderbolt link re-enumerates and NetworkManager re-applies the fixed address
  (`autoconnect` on the `thunderbolt-bridge` profile);
- the Deskflow client on the Mac reconnects on its own (keep it set to start at login);
- the lock watcher is always running and simply fails quietly while the cable is out;
- the extension reports "not reachable" until the link is back.

Nothing needs restarting. While the Mac is away, lock events are not delivered; the
machines just stop following each other.

## Thunderbolt bridge notes

- A Thunderbolt 3/4 or USB4 cable is required. With a plain USB-C cable the Mac
  enumerates as a USB 2.0 device instead and no usable network link appears.
- Linux: `thunderbolt-net` creates `thunderbolt0`. Give it a fixed link-local address so
  the Mac's self-assigned Thunderbolt Bridge address can always reach it:
  `nmcli con add type ethernet ifname thunderbolt0 con-name thunderbolt-bridge ipv4.method manual ipv4.addresses 169.254.99.1/16 ipv4.never-default yes ipv6.method link-local`
- macOS needs no configuration; Thunderbolt Bridge self-assigns 169.254.x.x, stable
  per machine. Find it on Omarchy with `ip -4 neigh show dev thunderbolt0`.

## Deskflow notes (Omarchy as server)

- Omarchy's desktop portal implements InputCapture, so `deskflow-core server` works on
  Hyprland with TLS and clipboard sync. Run it as a user service.
- Firewall: allow 24800/tcp on `thunderbolt0` only.
- Known quirk: the portal reports the screen in physical pixels while cursor positions
  are logical, so on a scale-2 display Deskflow sees only the top half of the edge.
  Compensate in the layout: `left(0,50) = mac(0,100)`.
- Headless server: the Mac's TLS fingerprint goes into
  `~/.config/Deskflow/tls/trusted-clients` as `v2:sha256:<hex>`; the Mac's hostname
  goes into an `aliases` section of the layout.

## Files and disks

Not part of this repo, but the same cable makes it easy:

- **Occasional transfers**: `scp` / `rsync` over the link, with a normal SSH key (the
  restricted continuity key can't do this on purpose).
- **A shared folder in Finder and in the file manager**: SMB. macOS has a built-in
  SMB server (System Settings, File Sharing) that Omarchy mounts with `smb://`;
  Samba on Omarchy does the reverse. Bind it to the Thunderbolt interface.
- **Fast and Unix-native**: NFS. macOS ships both an NFS client and server
  (`/etc/exports`, `nfsd enable`); Linux `nfs-utils`. Best throughput on the cable.
- **Block-level disk sharing** isn't practical between two running Macs-class machines
  (no iSCSI on macOS, Target Disk Mode needs the Mac rebooted). Use a network filesystem.

## Status

Built for a T2 MacBook Pro running Omarchy next to a 14" MacBook Pro. Not yet packaged;
run the install scripts from a checkout.
