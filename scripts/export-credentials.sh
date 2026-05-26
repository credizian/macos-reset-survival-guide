#!/bin/bash
# Build a single AES-256 encrypted DMG containing creds, dotfiles, and curated
# app state. Run BEFORE the macOS reset.
#
# Contents:
#   credentials/
#     ssh/          ~/.ssh (keys + pem files)
#     aws/          ~/.aws (config + credentials)
#     dotfiles/     .gitconfig, .zshrc, .zprofile, .zshenv, .zsh_history
#     claude/       ~/.claude (Claude Code CLI config, NOT desktop app)
#     config/       ~/.config (gh, gcloud, git, etc.)
#     home-root.tar.gz   CATCH-ALL of ~/ (minus caches/code) — see lesson 26
#   app-state/
#     MySQL-Workbench/     Saved connections + scripts + sql_history
#     Sublime-Text/        Packages + Lib + Local + Log
#     DBeaverData/         Workspaces + drivers
#     Raycast/             Config (encrypted DBs will be excluded on restore)
#     Claude/              local-agent-mode-sessions, settings, extensions
#     Documents-Claude/    Project files referenced by Cowork chats
#     preferences/         Curated .plist files
#
# The home-root.tar.gz catches what the curated copies above MISS — the random
# PEM keys, SQL dumps, Cognito exports, AI tool configs (.cloudflared, .azure,
# .docker, etc.), and any other ~/ root one-offs accumulated over years. This
# is the lesson from day 3 of the 2026 reset (see docs/01 lessons 26-31 and
# docs/05 for the full wipe-and-rediscover procedure).
#
# NOT included (these come back via sign-in to the app's own cloud):
#   VS Code Sync, Cursor Sync, browser profiles (Firefox/Chrome bookmarks
#   sync via account), Postman.
#
# You set the encryption password (hdiutil prompts). SAVE IT in your password
# manager — the backup is unrecoverable without it.

set -e

# --- CUSTOMIZE THIS for your external drive --------------------------------
FILES_VOL="/Volumes/T9 Files"
DEST="$FILES_VOL/mac-migration.dmg"
# ---------------------------------------------------------------------------

if [ ! -d "$FILES_VOL" ]; then
  echo "ERROR: '$FILES_VOL' not found. Plug in your external drive." >&2
  exit 1
fi

STAGING=$(mktemp -d /tmp/mac-migration.XXXXXX)
APPSUP="$HOME/Library/Application Support"
PREFS="$HOME/Library/Preferences"

echo "Staging into $STAGING ..."
mkdir -p "$STAGING/credentials/ssh" "$STAGING/credentials/aws" \
         "$STAGING/credentials/dotfiles" "$STAGING/credentials/claude" \
         "$STAGING/app-state/preferences" "$STAGING/app-state/Claude"

# --- credentials ---
cp -R ~/.ssh/. "$STAGING/credentials/ssh/" 2>/dev/null || true
[ -f ~/.aws/config ]      && cp ~/.aws/config      "$STAGING/credentials/aws/" 2>/dev/null || true
[ -f ~/.aws/credentials ] && cp ~/.aws/credentials "$STAGING/credentials/aws/" 2>/dev/null || true
for f in .gitconfig .zshrc .zprofile .zshenv .zsh_history; do
  [ -f ~/"$f" ] && cp ~/"$f" "$STAGING/credentials/dotfiles/" 2>/dev/null || true
done
# Claude Code CLI config (not the desktop app)
for f in CLAUDE.md settings.json settings.local.json; do
  [ -f ~/.claude/"$f" ] && cp ~/.claude/"$f" "$STAGING/credentials/claude/" 2>/dev/null || true
done
[ -d ~/.claude/rules ] && cp -R ~/.claude/rules "$STAGING/credentials/claude/" 2>/dev/null || true
# .config dir (cli tool configs)
[ -d ~/.config ] && cp -R ~/.config "$STAGING/credentials/config" 2>/dev/null || true

# --- app state ---
# IMPORTANT: MySQL Workbench's data dir is `MySQLWorkbench` (one word, no slash).
# A common mistake is `MySQL/Workbench` — that dir doesn't exist.
[ -d "$APPSUP/MySQLWorkbench" ]    && cp -R "$APPSUP/MySQLWorkbench"    "$STAGING/app-state/MySQL-Workbench" 2>/dev/null || true
[ -d "$APPSUP/Sublime Text" ]      && cp -R "$APPSUP/Sublime Text"      "$STAGING/app-state/Sublime-Text" 2>/dev/null || true
[ -d ~/Library/DBeaverData ]       && cp -R ~/Library/DBeaverData       "$STAGING/app-state/DBeaverData" 2>/dev/null || true
[ -d "$APPSUP/com.raycast.macos" ] && cp -R "$APPSUP/com.raycast.macos" "$STAGING/app-state/Raycast" 2>/dev/null || true

# --- Claude Desktop app (the critical Cowork data) ---
# These paths weren't backed up in my original script and required mounting a
# Time Machine snapshot to recover. See docs/02-cowork-recovery.md for the
# story. This now covers what you actually need.
CLAUDE_APP="$APPSUP/Claude"
if [ -d "$CLAUDE_APP" ]; then
  # The critical data: Cowork chats, scheduled tasks, projects, agent state
  [ -d "$CLAUDE_APP/local-agent-mode-sessions" ] && \
    cp -R "$CLAUDE_APP/local-agent-mode-sessions" "$STAGING/app-state/Claude/" 2>/dev/null || true
  # Config + extensions
  for f in claude_desktop_config.json extensions-installations.json \
           cowork-enabled-cli-ops.json git-worktrees.json window-state.json; do
    [ -f "$CLAUDE_APP/$f" ] && cp "$CLAUDE_APP/$f" "$STAGING/app-state/Claude/" 2>/dev/null || true
  done
  [ -d "$CLAUDE_APP/Claude Extensions" ]          && cp -R "$CLAUDE_APP/Claude Extensions"          "$STAGING/app-state/Claude/" 2>/dev/null || true
  [ -d "$CLAUDE_APP/Claude Extensions Settings" ] && cp -R "$CLAUDE_APP/Claude Extensions Settings" "$STAGING/app-state/Claude/" 2>/dev/null || true
  # NOT copied:
  #   config.json     — has OAuth tokens; will be recreated on new Mac sign-in
  #   vm_bundles/     — 12 GB of regenerable Electron containers
  #   Cache/, GPUCache/, Code Cache/, Local Storage/, IndexedDB/ — caches
fi

# --- ~/Documents/Claude — project files referenced by Cowork chats ---
[ -d "$HOME/Documents/Claude" ] && cp -R "$HOME/Documents/Claude" "$STAGING/app-state/Documents-Claude" 2>/dev/null || true

# --- preference plists (these survive a reset and restore cleanly) ---
for p in com.oracle.workbench.MySQLWorkbench com.sublimetext.4 \
         org.jkiss.dbeaver.core.product com.knollsoft.Rectangle \
         com.raycast.macos com.googlecode.iterm2; do
  [ -f "$PREFS/$p.plist" ] && cp "$PREFS/$p.plist" "$STAGING/app-state/preferences/" 2>/dev/null || true
done

# --- HOME ROOT CATCH-ALL ---
# Curated copies above capture what we REMEMBER to enumerate. This sweep
# catches what we DON'T — the random PEM keys, SQL dumps, JSON exports, and
# hidden AI-tool config dirs that accumulate at ~/ root over years.
#
# Without this: post-restore, a `comm -23` between snapshot ~/ and live ~/
# typically reveals 50-100 missed files. See docs/05-wiping-old-backup-drive.md
# for the diff-find procedure.
#
# Exclude list is a DENYLIST (skip caches and code we have elsewhere). Keep
# the file-format excludes generous: an unneeded file in the backup is cheap;
# a missing private key is expensive.
echo ""
echo "Building home-root catch-all sweep (this is the broad insurance layer)..."
tar -czf "$STAGING/credentials/home-root.tar.gz" -C "$HOME" . \
  --exclude='./a_code_project' --exclude='./code' --exclude='./src' \
  --exclude='./Library' --exclude='./node_modules' --exclude='./venv' \
  --exclude='./nltk_data' --exclude='./Documents/Claude' \
  --exclude='./.ollama' --exclude='./.gradle' --exclude='./.konan' \
  --exclude='./.virtualenvs' --exclude='./.gem' \
  --exclude='./.npm' --exclude='./.yarn' --exclude='./.pnpm-store' \
  --exclude='./.cache' --exclude='./.nvm' --exclude='./.pyenv' \
  --exclude='./.rustup' --exclude='./.cargo' --exclude='./.m2' --exclude='./.ivy2' \
  --exclude='./.sbt' --exclude='./.cocoapods' --exclude='./.bun' \
  --exclude='./.Trash' --exclude='./.DS_Store' \
  --exclude='./Dropbox' --exclude='./OneDrive*' \
  --exclude='./iCloud Drive (Archive)' \
  --exclude='Cache' --exclude='Code Cache' --exclude='CachedData' \
  --exclude='GPUCache' --exclude='Crashpad' --exclude='blob_storage' \
  --exclude='Service Worker' --exclude='Session Storage' \
  --exclude='Local Storage' --exclude='IndexedDB' \
  --exclude='avd' --exclude='build-cache' \
  --exclude='java_error*.log' --exclude='jbr_err*.log' \
  --exclude='firebase-debug.log' \
  2>/dev/null || true
echo "Home-root sweep: $(du -sh "$STAGING/credentials/home-root.tar.gz" | cut -f1)"

# Verify the keys actually made it into the sweep
KEY_COUNT=$(tar -tzf "$STAGING/credentials/home-root.tar.gz" 2>/dev/null \
  | grep -cE '\.pem$|\.key$|keystore$' || echo 0)
echo "Private keys captured in home-root.tar.gz: $KEY_COUNT"

echo ""
echo "Staged:"
du -sh "$STAGING"/*/* 2>/dev/null | sort -rh | head -20
echo ""
TOTAL=$(du -sh "$STAGING" 2>/dev/null | cut -f1)
echo "Total staged: $TOTAL"
echo ""

echo "=========================================================="
echo "Creating AES-256 encrypted disk image."
echo "hdiutil will prompt for a password — CHOOSE A STRONG ONE,"
echo "SAVE IT in your password manager. It cannot be recovered."
echo "=========================================================="
hdiutil create -encryption AES-256 -volname "MacMigration" -fs APFS \
  -srcfolder "$STAGING" -ov "$DEST"

echo ""
echo "Shredding unencrypted staging..."
rm -rf "$STAGING"

echo ""
echo "DONE. Encrypted migration backup:"
ls -lh "$DEST"
echo ""
echo "Restore later: double-click the .dmg, enter password, then run restore.sh."
