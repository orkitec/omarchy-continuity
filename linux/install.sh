#!/bin/bash
# Linux side of omarchy-continuity.
#
#   linux/install.sh <mac-public-key | .pub path> [thunderbolt-interface]
#
# - installs the SSH forced command and authorizes the Mac's key for it only
# - opts the face-unlock lock screen into IPC unlock
# - creates this machine's key for the reverse direction (tab hand-off, lock the Mac)
#   and prints it for mac/install.sh --authorize
# - installs the browser native-messaging host for Chromium and Chrome
# - with sudo: key-only sshd drop-in, enable sshd, allow port 22 on the Thunderbolt link
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
PUB="${1:?public key (string or .pub path) printed by mac/install.sh}"
IFACE="${2:-thunderbolt0}"
[[ -f $PUB ]] && PUB=$(<"$PUB")
MAC_HOST="${OC_MAC_HOST:-}"   # optional: the Mac's Thunderbolt address, else discovered below

install -Dm755 "$HERE/omarchy-continuityd" "$HOME/.local/bin/omarchy-continuityd"

# --- awake heartbeat watchdog: gives the idle lock back when the Mac's heartbeat stops ---
install -Dm755 "$HERE/omarchy-continuity-idle-watch" "$HOME/.local/bin/omarchy-continuity-idle-watch"
install -Dm644 "$HERE/systemd/omarchy-continuity-idle.service" "$HOME/.config/systemd/user/omarchy-continuity-idle.service"
install -Dm644 "$HERE/systemd/omarchy-continuity-idle.timer" "$HOME/.config/systemd/user/omarchy-continuity-idle.timer"

# --- clipboard: every copy here goes to the Mac (Deskflow's Wayland clipboard is unreliable) ---
install -Dm755 "$HERE/omarchy-continuity-clip-watch" "$HOME/.local/bin/omarchy-continuity-clip-watch"
install -Dm644 "$HERE/systemd/omarchy-continuity-clip.service" "$HOME/.config/systemd/user/omarchy-continuity-clip.service"
systemctl --user daemon-reload
systemctl --user enable --now omarchy-continuity-idle.timer >/dev/null
systemctl --user enable omarchy-continuity-clip.service >/dev/null
systemctl --user restart omarchy-continuity-clip.service

# --- accept the Mac's key, restricted to the daemon and to link-local sources ---
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
LINE="restrict,from=\"169.254.0.0/16\",command=\"$HOME/.local/bin/omarchy-continuityd\" $PUB"
KEYPART=$(cut -d' ' -f2 <<<"$PUB")
if grep -qF -- "$KEYPART" "$HOME/.ssh/authorized_keys"; then
  # Replace an existing entry for this key so a changed restriction line takes effect.
  grep -vF -- "$KEYPART" "$HOME/.ssh/authorized_keys" > "$HOME/.ssh/authorized_keys.tmp" || true
  echo "$LINE" >> "$HOME/.ssh/authorized_keys.tmp"
  mv "$HOME/.ssh/authorized_keys.tmp" "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
  echo "updated the Mac key's entry"
else
  echo "$LINE" >> "$HOME/.ssh/authorized_keys"
  echo "authorized the Mac's key, restricted to omarchy-continuityd"
fi

# --- lock screen: allow `omarchy-shell lock unlock` (orkitec/omarchy-face-unlock, opt-in) ---
mkdir -p "$HOME/.config/omarchy/face-unlock" && touch "$HOME/.config/omarchy/face-unlock/ipc-unlock"

# --- this machine's key towards the Mac ---
KEY="$HOME/.ssh/omarchy-continuity"
if [[ ! -f $KEY ]]; then
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "omarchy-continuity@$(hostname)" >/dev/null
  echo "created $KEY"
fi

# --- peer config for the native host (the Mac on the Thunderbolt bridge) ---
if [[ -z $MAC_HOST ]]; then
  MAC_HOST=$(ip -4 neigh show dev "$IFACE" 2>/dev/null | awk '/169\.254\./{print $1; exit}')
fi
mkdir -p "$HOME/.config/omarchy-continuity"
cat > "$HOME/.config/omarchy-continuity/peer" <<EOF
host=${MAC_HOST:-CHANGE-ME}
user=${OC_MAC_USER:-$USER}
key=$KEY
EOF
[[ -n $MAC_HOST ]] || echo "note: could not discover the Mac's address; edit host= in ~/.config/omarchy-continuity/peer"

# --- browser native messaging host (Chromium + Chrome) ---
install -Dm755 "$ROOT/native/omarchy-continuity-native" "$HOME/.local/bin/omarchy-continuity-native"
EXT_ID=$(<"$ROOT/extension/ID")
for d in "$HOME/.config/chromium/NativeMessagingHosts" "$HOME/.config/google-chrome/NativeMessagingHosts"; do
  mkdir -p "$d"
  sed -e "s|@PATH@|$HOME/.local/bin/omarchy-continuity-native|" -e "s|@EXT_ID@|$EXT_ID|" \
    "$ROOT/native/com.orkitec.omarchy_continuity.json" > "$d/com.orkitec.omarchy_continuity.json"
done

echo "--- privileged part: sshd drop-in, enable sshd, firewall rule on $IFACE ---"
sudo install -Dm644 "$HERE/sshd/50-omarchy-continuity.conf" /etc/ssh/sshd_config.d/50-omarchy-continuity.conf
sudo systemctl enable --now sshd
if command -v ufw >/dev/null; then
  sudo ufw allow in on "$IFACE" to any port 22 proto tcp comment "omarchy-continuity (SSH over Thunderbolt only)"
fi

cat <<EOF

done.
1. Load the extension: chrome://extensions -> Developer mode -> Load unpacked -> $ROOT/extension
2. Authorize this machine on the Mac:   mac/install.sh --authorize '$(<"$KEY.pub")'
3. Test from the Mac:                   ssh -i ~/.ssh/omarchy-continuity $USER@169.254.99.1 status
EOF
