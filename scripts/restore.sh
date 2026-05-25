#!/bin/bash
# Restore a freshly-installed Mac from the backup DMG + code mirror produced
# by export-credentials.sh and mirror-to-t9.sh.
#
# Run this AFTER macOS clean install, AFTER signing into Mac App Store
# (so the mas entries in Brewfile actually install), and AFTER plugging in
# your external drive.
#
# Interactive prompts during the run:
#   - Xcode Command Line Tools GUI installer (press Enter when done)
#   - sudo password (for /usr/local/cli-plugins pre-create and computer name)
#   - DMG password (when mounting the encrypted backup)
#
# Manual steps NOT done by this script — they need a real TTY:
#   - macOS Setup Assistant (Apple ID, etc.)
#   - Mac App Store sign-in (must be done BEFORE `brew bundle install`)
#   - `ssh-add --apple-use-keychain` (passphrase prompt; run in Terminal.app
#     directly, NEVER via a shell-out from an AI tool — the passphrase will
#     leak into the chat transcript)
#   - `gh auth login` + `gh auth refresh -s admin:public_key` (browser flow)
#   - GitHub Desktop sign-in (then bulk-add repos via the github CLI)
#   - Sign-ins to Dropbox / iCloud (NOT Documents sync!) / etc.

set -e

# --- CUSTOMIZE THESE for your external drive setup ----------------------
T9="/Volumes/T9 Files"
BACKUP_DIR="$T9/mac-reset-backup"        # holds Brewfile + this script
DMG="$T9/mac-migration.dmg"              # encrypted backup
CODE_MIRROR="$T9/a_code_project"         # rsync mirror of your code dir
CODE_DEST="$HOME/a_code_project"         # local destination
# ------------------------------------------------------------------------

if [ ! -d "$T9" ]; then
  echo "ERROR: '$T9' not mounted. Plug in the external drive." >&2
  exit 1
fi
if [ ! -f "$DMG" ]; then
  echo "ERROR: '$DMG' not found." >&2
  exit 1
fi
if [ ! -f "$BACKUP_DIR/Brewfile" ]; then
  echo "ERROR: '$BACKUP_DIR/Brewfile' not found." >&2
  exit 1
fi

echo "================================================================"
echo "macOS restoration starting"
echo "================================================================"
echo "External drive: $T9"
echo "Brewfile:       $BACKUP_DIR/Brewfile ($(wc -l < "$BACKUP_DIR/Brewfile") lines)"
echo "DMG:            $DMG ($(du -h "$DMG" | cut -f1))"
echo ""

# ---------- 1. Xcode Command Line Tools ----------
echo "==> Step 1/10: Xcode Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then
  echo "    Already installed: $(xcode-select -p)"
else
  xcode-select --install
  echo "    GUI installer launched. Click Install in the prompt, then come back."
  read -p "    Press Enter once the install is complete..." _
fi

# ---------- 2. Homebrew ----------
echo ""
echo "==> Step 2/10: Homebrew"
if command -v brew >/dev/null 2>&1; then
  echo "    Already installed: $(brew --version | head -1)"
else
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi
if [ -d /opt/homebrew/bin ]; then
  export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
fi

# ---------- 3. Pre-create /usr/local/cli-plugins for Docker ----------
# docker-desktop's brew cask shells out to `sudo mkdir` and can't prompt
# non-interactively from brew. Pre-create the directory with the right
# ownership and Docker installs cleanly.
echo ""
echo "==> Step 3/10: Pre-creating /usr/local/cli-plugins for Docker"
if [ ! -d /usr/local/cli-plugins ]; then
  sudo mkdir -p /usr/local/cli-plugins
  sudo chown "$USER" /usr/local/cli-plugins
  echo "    Created and chowned to $USER"
else
  echo "    Already exists"
fi

# ---------- 4. Brewfile ----------
# Critical PATH export: brew bundle's npm step runs in a non-interactive shell
# where node@24 isn't on PATH. Without this, every `npm "..."` line fails.
echo ""
echo "==> Step 4/10: brew bundle install (this is the long one — 15-25 min)"
echo "    REMINDER: Did you sign into Mac App Store? Required for mas entries."
cd "$BACKUP_DIR"
export PATH="/opt/homebrew/opt/node@24/bin:$PATH"
brew bundle install --file=Brewfile || {
  echo "    Some entries failed. Re-run brew bundle after fixing whatever's flagged."
  echo "    (Casks renamed upstream, MAS not signed in, etc.)"
}

# ---------- 5. Mount the migration DMG ----------
echo ""
echo "==> Step 5/10: Mounting encrypted migration backup"
echo "    You'll be prompted for the DMG password."
hdiutil attach "$DMG"
MNT="/Volumes/MacMigration"
[ ! -d "$MNT" ] && { echo "    ERROR: DMG didn't mount at $MNT" >&2; exit 1; }

# ---------- 6. Restore credentials & app state ----------
echo ""
echo "==> Step 6/10: Restoring credentials, dotfiles, app state"

# SSH
mkdir -p ~/.ssh
cp -R "$MNT/credentials/ssh/." ~/.ssh/ 2>/dev/null || true
echo "    ssh keys restored"

# AWS
mkdir -p ~/.aws
cp -R "$MNT/credentials/aws/." ~/.aws/ 2>/dev/null || true
echo "    aws creds restored"

# Dotfiles
for f in .gitconfig .zshrc .zprofile .zshenv .zsh_history; do
  [ -f "$MNT/credentials/dotfiles/$f" ] && cp "$MNT/credentials/dotfiles/$f" ~/
done
echo "    dotfiles restored"

# Claude Code CLI (~/.claude — NOT the desktop app)
mkdir -p ~/.claude
cp -R "$MNT/credentials/claude/." ~/.claude/ 2>/dev/null || true
echo "    Claude Code CLI config restored"

# .config (gh, gcloud, git, raycast cli, etc.)
if [ -d "$MNT/credentials/config" ]; then
  mkdir -p ~/.config
  cp -R "$MNT/credentials/config/." ~/.config/ 2>/dev/null || true
  echo "    .config restored"
fi

# MySQL Workbench (dir name is `MySQLWorkbench`, one word, no slash)
if [ -d "$MNT/app-state/MySQL-Workbench" ]; then
  mkdir -p ~/Library/Application\ Support/MySQLWorkbench
  cp -R "$MNT/app-state/MySQL-Workbench/." ~/Library/Application\ Support/MySQLWorkbench/
  echo "    MySQL Workbench restored (passwords need re-entry on first connect)"
fi

# Sublime Text
if [ -d "$MNT/app-state/Sublime-Text" ]; then
  mkdir -p ~/Library/Application\ Support
  cp -R "$MNT/app-state/Sublime-Text" ~/Library/Application\ Support/Sublime\ Text
  echo "    Sublime Text restored"
fi

# DBeaver
if [ -d "$MNT/app-state/DBeaverData" ]; then
  cp -R "$MNT/app-state/DBeaverData" ~/Library/
  echo "    DBeaver restored (passwords need re-entry)"
fi

# Raycast — EXCLUDE encrypted DBs.
# raycast-enc.sqlite* are encrypted at rest with a key from old Mac's Keychain.
# Without that key, Raycast shows "Database Exception" on first launch.
# Restoring the structure without these lets Raycast initialize fresh, then
# cloud sync (Pro plan) brings settings back.
if [ -d "$MNT/app-state/Raycast" ]; then
  mkdir -p ~/Library/Application\ Support/com.raycast.macos
  rsync -a \
    --exclude='raycast-enc.sqlite*' \
    --exclude='raycast-activities-enc.sqlite*' \
    "$MNT/app-state/Raycast/" ~/Library/Application\ Support/com.raycast.macos/
  echo "    Raycast restored (encrypted DBs excluded — sign in for cloud sync)"
fi

# Claude Desktop app (Cowork chats, scheduled tasks, projects, extensions)
if [ -d "$MNT/app-state/Claude" ]; then
  CLAUDE_APP_DIR="$HOME/Library/Application Support/Claude"
  mkdir -p "$CLAUDE_APP_DIR"
  [ -d "$MNT/app-state/Claude/local-agent-mode-sessions" ] && \
    rsync -a "$MNT/app-state/Claude/local-agent-mode-sessions/" \
             "$CLAUDE_APP_DIR/local-agent-mode-sessions/"
  for f in claude_desktop_config.json extensions-installations.json \
           cowork-enabled-cli-ops.json git-worktrees.json window-state.json; do
    if [ -f "$MNT/app-state/Claude/$f" ]; then
      # Don't clobber config.json — has fresh OAuth from new Mac sign-in
      [ "$f" = "claude_desktop_config.json" ] || [ ! -f "$CLAUDE_APP_DIR/$f" ] && \
        cp "$MNT/app-state/Claude/$f" "$CLAUDE_APP_DIR/$f"
    fi
  done
  for sub in "Claude Extensions" "Claude Extensions Settings"; do
    if [ -d "$MNT/app-state/Claude/$sub" ]; then
      mkdir -p "$CLAUDE_APP_DIR/$sub"
      rsync -a "$MNT/app-state/Claude/$sub/" "$CLAUDE_APP_DIR/$sub/"
    fi
  done
  echo "    Claude Desktop app data restored"
fi

# ~/Documents/Claude — project files Cowork chats reference
if [ -d "$MNT/app-state/Documents-Claude" ]; then
  mkdir -p ~/Documents/Claude
  rsync -a "$MNT/app-state/Documents-Claude/" ~/Documents/Claude/
  echo "    ~/Documents/Claude restored (project files for Cowork chats)"
fi

# Preference plists
if [ -d "$MNT/app-state/preferences" ]; then
  cp "$MNT/app-state/preferences/"*.plist ~/Library/Preferences/ 2>/dev/null || true
  echo "    preference plists restored"
fi

# ---------- 6b. Patch ~/.ssh/config for Homebrew openssh compat ----------
# `IgnoreUnknown UseKeychain` must be at GLOBAL scope, not inside a Host
# block. Homebrew's openssh doesn't recognize UseKeychain and parsing fails
# on the entire file if IgnoreUnknown is buried in a block.
echo ""
echo "==> Patching ~/.ssh/config (global IgnoreUnknown scope)"
if [ -f ~/.ssh/config ] && ! head -5 ~/.ssh/config | grep -q "^IgnoreUnknown UseKeychain"; then
  cp ~/.ssh/config ~/.ssh/config.pre-fix.bak
  {
    echo "# Global scope - applies to all Host blocks below"
    echo "IgnoreUnknown UseKeychain"
    echo "AddKeysToAgent yes"
    echo "UseKeychain yes"
    echo ""
    cat ~/.ssh/config
  } > ~/.ssh/config.new
  mv ~/.ssh/config.new ~/.ssh/config
  echo "    Patched (backup at ~/.ssh/config.pre-fix.bak)"
fi

# ---------- 7. Code mirror ----------
echo ""
echo "==> Step 7/10: Restoring code mirror via rsync"
if [ -d "$CODE_MIRROR" ]; then
  mkdir -p "$CODE_DEST"
  # Note: NO --info=progress2 — macOS system rsync is too old.
  rsync -a "$CODE_MIRROR/" "$CODE_DEST/"
  repo_count=$(find "$CODE_DEST" -maxdepth 3 -name ".git" -type d 2>/dev/null | wc -l | tr -d ' ')
  size=$(du -sh "$CODE_DEST" 2>/dev/null | awk '{print $1}')
  echo "    $repo_count git repos / $size restored to $CODE_DEST"
fi

# ---------- 8. SSH perms + known_hosts ----------
# Pre-populate known_hosts so first `ssh -T git@github.com` doesn't fail.
# GitHub's fingerprints are public + documented; we trust them.
echo ""
echo "==> Step 8/10: SSH permissions + known_hosts"
chmod 700 ~/.ssh 2>/dev/null || true
chmod 600 ~/.ssh/id_* ~/.ssh/*.pem ~/.ssh/config 2>/dev/null || true
chmod 644 ~/.ssh/*.pub ~/.ssh/known_hosts* 2>/dev/null || true
touch ~/.ssh/known_hosts
for host in github.com gitlab.com; do
  if ! grep -q "^$host " ~/.ssh/known_hosts 2>/dev/null; then
    ssh-keyscan -t ed25519,ecdsa,rsa "$host" >> ~/.ssh/known_hosts 2>/dev/null
  fi
done
echo "    Set perms + added github.com / gitlab.com to known_hosts"

# ---------- 8b. Firefox profile fix for 138+ Profile Groups system ----------
# Firefox 138+ added a "Profile Groups" SQLite-based picker that ignores
# profiles.ini. After a restore from a pre-138 backup, the new picker shows
# only a "Create a profile" button — your restored profiles are invisible.
# Disable the new picker via user.js in each restored profile dir.
echo ""
echo "==> Firefox profile fix (disable Firefox 138+ Profile Groups picker)"
FF_PROFILES="$HOME/Library/Application Support/Firefox/Profiles"
if [ -d "$FF_PROFILES" ]; then
  for prof in "$FF_PROFILES"/*/; do
    if [ -f "$prof/places.sqlite" ] && [ ! -f "$prof/user.js" ]; then
      echo 'user_pref("browser.profiles.enabled", false);' > "$prof/user.js"
    fi
  done
  echo "    Wrote user.js to all restored profiles"
fi

# ---------- 9. Sweep stale .git/*.lock in Dropbox-hosted repos ----------
# Dropbox sometimes preserves stale lock files from interrupted git
# operations, blocking commits in any repos kept under Dropbox.
echo ""
echo "==> Step 9/10: Sweeping stale .git/*.lock in Dropbox repos"
if [ -d "$HOME/Dropbox" ]; then
  find "$HOME/Dropbox" -name "*.lock" -type f -path "*/.git/*" -delete 2>/dev/null
  echo "    Done"
else
  echo "    No ~/Dropbox dir; skipping"
fi

# ---------- 10. Unmount DMG ----------
echo ""
echo "==> Step 10/10: Unmounting DMG"
hdiutil detach "$MNT"

echo ""
echo "================================================================"
echo "RESTORATION COMPLETE"
echo "================================================================"
echo ""
echo "What's done automatically:"
echo "  ✓ Homebrew + all apps + casks from Brewfile"
echo "  ✓ SSH keys + ~/.ssh/config patch + known_hosts populated"
echo "  ✓ AWS creds, dotfiles, Claude Code CLI config, .config"
echo "  ✓ MySQL Workbench, Sublime, DBeaver, Raycast (sans encrypted DBs)"
echo "  ✓ Claude Desktop: sessions, chats, projects, extensions, trusted folders"
echo "  ✓ ~/Documents/Claude project files"
echo "  ✓ Preference plists"
echo "  ✓ Code mirror rsync'd"
echo "  ✓ Stale .git/*.lock swept in Dropbox repos"
echo ""
echo "Now do these manually (Terminal.app — NOT via AI tool shell-out):"
echo "  1. /usr/bin/ssh-add --apple-use-keychain ~/.ssh/id_ed25519"
echo "  2. gh auth login"
echo "  3. gh auth refresh -s admin:public_key"
echo "  4. gh ssh-key add ~/.ssh/id_ed25519.pub --title \"\$(scutil --get ComputerName)\""
echo "  5. Launch GitHub Desktop and SIGN IN first. Then (with Desktop OPEN):"
echo "       find $CODE_DEST -maxdepth 3 -name .git -type d | sed 's|/.git\$||' |"
echo "         while read r; do github \"\$r\"; sleep 1.5; done"
echo "     NOTE: Throttle MUST be ~1.5s and Desktop MUST be visible — anything"
echo "     less and only the last repo persists to IndexedDB."
echo "  6. Sign into iCloud (NOT Desktop/Documents sync), Dropbox, etc."
echo "  7. Open Docker.app once to start the daemon"
echo "  8. Grant Privacy & Security perms (Full Disk Access, Accessibility)"
echo ""
echo "Then verify: bash '$BACKUP_DIR/verify-setup.sh'"
