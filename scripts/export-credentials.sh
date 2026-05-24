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
#   app-state/
#     MySQL-Workbench/     Saved connections + scripts + sql_history
#     Sublime-Text/        Packages + Lib + Local + Log
#     DBeaverData/         Workspaces + drivers
#     Raycast/             Config (encrypted DBs will be excluded on restore)
#     Claude/              local-agent-mode-sessions, settings, extensions
#     Documents-Claude/    Project files referenced by Cowork chats
#     preferences/         Curated .plist files
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
