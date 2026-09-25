#!/bin/bash
# macOS side of omarchy-continuity.
#
#   mac/install.sh [omarchy-host] [omarchy-user]     build + install the lock watcher, key, native host
#   mac/install.sh --authorize '<omarchy public key>' accept the Omarchy machine's key (tab hand-off,
#                                                     lock this Mac) and turn on Remote Login
#
# Defaults: omarchy-host 169.254.99.1 (Thunderbolt bridge), omarchy-user = your macOS username.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SUPPORT="$HOME/Library/Application Support/omarchy-continuity"
KEY="$HOME/.ssh/omarchy-continuity"
LOG="$HOME/Library/Logs/omarchy-continuity.log"
PLIST="$HOME/Library/LaunchAgents/com.orkitec.omarchy-continuity.plist"

if [[ ${1:-} == "--authorize" ]]; then
  PUB="${2:?public key printed by linux/install.sh}"
  [[ -f $PUB ]] && PUB=$(<"$PUB")
  install -m755 "$HERE/omarchy-continuityd" "$SUPPORT/omarchy-continuityd"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
  # The path contains a space ("Application Support") and sshd hands command= to the
  # login shell with -c, so it must be single-quoted inside the clause.
  LINE="restrict,from=\"169.254.0.0/16\",command=\"'$SUPPORT/omarchy-continuityd'\" $PUB"
  KEYPART=$(cut -d' ' -f2 <<<"$PUB")
  if grep -qF -- "$KEYPART" "$HOME/.ssh/authorized_keys"; then
    # Replace an existing entry for this key so a fixed restriction line takes effect.
    grep -vF -- "$KEYPART" "$HOME/.ssh/authorized_keys" > "$HOME/.ssh/authorized_keys.tmp" || true
    echo "$LINE" >> "$HOME/.ssh/authorized_keys.tmp"
    mv "$HOME/.ssh/authorized_keys.tmp" "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
    echo "updated the Omarchy machine's key entry"
  else
    echo "$LINE" >> "$HOME/.ssh/authorized_keys"
    echo "authorized the Omarchy machine's key, restricted to omarchy-continuityd"
  fi
  echo "turning on Remote Login (sudo)..."
  sudo systemsetup -setremotelogin on
  echo "done. Test from Omarchy: ssh -i ~/.ssh/omarchy-continuity $USER@<this Mac's 169.254 address> status"
  exit 0
fi

HOST="${1:-169.254.99.1}"
RUSER="${2:-$USER}"

if ! xcrun -f swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
echo "building lockwatcher..."
swiftc -O -o "$SUPPORT/lockwatcher" "$HERE/LockWatcher.swift"

if [[ ! -f $KEY ]]; then
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "omarchy-continuity@$(scutil --get LocalHostName)" >/dev/null
  echo "created key $KEY"
fi
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
ssh-keyscan -T 3 -t ed25519 "$HOST" 2>/dev/null >> "$HOME/.ssh/known_hosts" || echo "note: host key not fetched yet (sshd on $HOST not up?); accepted on first use"

# peer config for the native host
cat > "$SUPPORT/peer" <<EOF
host=$HOST
user=$RUSER
key=$KEY
EOF

# browser native messaging host (Chrome; Chromium/Brave use their own dirs, add if needed)
install -m755 "$ROOT/native/omarchy-continuity-native" "$SUPPORT/omarchy-continuity-native"
EXT_ID=$(<"$ROOT/extension/ID")
NM="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "$NM"
sed -e "s|@PATH@|$SUPPORT/omarchy-continuity-native|" -e "s|@EXT_ID@|$EXT_ID|" \
  "$ROOT/native/com.orkitec.omarchy_continuity.json" > "$NM/com.orkitec.omarchy_continuity.json"

# lock watcher LaunchAgent
sed -e "s|@BIN@|$SUPPORT|g" -e "s|@HOST@|$HOST|g" -e "s|@USER@|$RUSER|g" -e "s|@KEY@|$KEY|g" -e "s|@LOG@|$LOG|g" \
  "$HERE/com.orkitec.omarchy-continuity.plist" > "$PLIST"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

cat <<EOF

lock watcher installed and running (log: $LOG)
1. Authorize this Mac on Omarchy:   linux/install.sh '$(<"$KEY.pub")'
2. Load the extension in Chrome:    chrome://extensions -> Developer mode -> Load unpacked -> $ROOT/extension
3. After linux/install.sh printed the Omarchy key, run here:  mac/install.sh --authorize '<that key>'
EOF
