# Reset-day playbook — ordered, time-budgeted

Total ~75 minutes hands-on. Productive on code at the ~50-minute mark.

## Pre-flight (~5 min, day before reset)

- [ ] **Run `scripts/mirror-to-t9.sh`** to refresh the code mirror. Last chance to capture WIP.
- [ ] **Run `scripts/export-credentials.sh`** to create the encrypted backup DMG. Save the password in your password manager.
- [ ] Verify external drive shows both volumes (`T9 Files` for the DMG + mirror, `T9 Backup` for Time Machine — or whatever you've named them).
- [ ] Optional: run a final manual Time Machine backup: `tmutil status` to check, click Back Up Now in System Settings.

## Pre-flight (~5 min, reset morning)

- [ ] T9 plugged in, stays plugged in throughout.
- [ ] System Settings → Apple ID → Find My Mac → OFF
- [ ] System Settings → Apple ID → Sign Out → "Keep a Copy on Mac"
- [ ] Messages → Settings → iMessage → Sign Out
- [ ] FaceTime → Settings → Sign Out
- [ ] App Store → Account → Sign Out
- [ ] Any DRM-licensed apps (Studio One, etc.): deactivate license
- [ ] Quit all open apps (Cmd+Q for each)

## Erase (~10 min, passive)

System Settings → General → Transfer or Reset → **Erase All Content and Settings**. Enter password, confirm, Mac restarts a few times, lands on "Hello" screen.

Switch to viewing this guide on your phone — Mac is wiping.

## Setup Assistant (~10 min)

| Screen | Action |
|---|---|
| Language | English |
| Region | (your region) |
| Wi-Fi | Connect |
| Data & Privacy | Continue |
| **⚠ Transfer Your Information** | **"Don't transfer any information now"** — using Migration Assistant defeats the point of a clean install |
| Apple ID | Sign in |
| Terms | Agree |
| Computer account | Same name/password as before (so paths still resolve) |
| Touch ID | Set up |
| Apple Intelligence | OFF (or ON if you use it) |
| Analytics | OFF |
| FileVault | **ON** |
| Siri | Your call |

Land on desktop.

## Sign into App Store (~2 min)

**Before running restore.sh** — Apple menu → App Store → Sign In. Required for the `mas` entries in your Brewfile to install. Without this, every `mas "App Name"` line silently no-ops.

## Run restore.sh (~30-40 min, mostly passive)

```bash
bash "/Volumes/T9 Files/mac-reset-backup/restore.sh"
```

You'll be prompted for:

| Step | What happens |
|---|---|
| Xcode CLT | GUI installer pops up → click Install → wait → press Enter in Terminal |
| sudo password | For `/usr/local/cli-plugins` pre-create (Docker) and computer name |
| DMG password | When the encrypted backup mounts |
| `brew bundle install` | 15-25 min. Walk away. |

What it does (no input needed):
- Installs Homebrew + 100+ formulae + 10 casks + MAS apps + VS Code extensions + npm globals
- Restores SSH keys, AWS creds, dotfiles, Claude Code CLI config, .config
- Restores MySQL Workbench connections, Sublime Text, DBeaver, Raycast (excl. encrypted DBs)
- Restores Claude Desktop data (Cowork sessions, projects, extensions, trusted folders)
- Restores `~/Documents/Claude` project files
- Patches `~/.ssh/config` to be Homebrew-openssh-compatible
- Pre-populates `~/.ssh/known_hosts` with github.com + gitlab.com
- Sweeps stale `.git/*.lock` in any Dropbox-hosted repos
- Rsyncs your code mirror

## Manual sign-ins (~20 min)

⚠ **For `ssh-add` — run in Terminal.app directly. Never via an AI tool's shell-out prefix** (the passphrase prompt won't get TTY input and can leak into chat).

```bash
/usr/bin/ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```

Then GitHub:
```bash
gh auth login                                                            # HTTPS, browser flow
gh auth refresh -s admin:public_key                                      # Needed for next step
gh ssh-key add ~/.ssh/id_ed25519.pub --title "$(scutil --get ComputerName) $(date +%Y-%m-%d)"
```

Verify AWS:
```bash
aws sts get-caller-identity
# If SSO: aws sso login
```

Open and sign into each (in priority order):
- [ ] **iCloud** — System Settings → Apple ID. ⚠ **Do NOT enable iCloud Desktop & Documents Sync** unless you specifically want it (it changes how `~/Documents` works and can cause Finder hangs)
- [ ] **Dropbox** — open app → sign in → re-sync starts
- [ ] **OneDrive** — sign in if you use it
- [ ] **1Password** — sign in → enable Safari extension
- [ ] **GitHub Desktop** — sign in. Then bulk-add repos (Desktop must be OPEN and visible, throttle 1.5s — anything less and only the last repo persists to IndexedDB; see lesson 25):
  ```bash
  find ~/a_code_project -maxdepth 3 -name .git -type d | sed 's|/.git$||' |
    while read r; do github "$r"; sleep 1.5; done
  ```
- [ ] **VS Code** — sign in → enable Settings Sync
- [ ] **Cursor** — sign in → enable settings sync
- [ ] **Arc** — sign in (spaces/tabs/bookmarks come back)
- [ ] **Slack / ClickUp** — sign into each workspace
- [ ] **Raycast** — sign in for cloud sync (replaces the empty-config state)
- [ ] **Claude Desktop** — sign in (Cowork data populates from the restored sessions dir)
- [ ] **Telegram / WhatsApp** — QR scan from phone
- [ ] **Postman** — sign in

## System Settings (~10 min)

### Privacy & Security
- [ ] Full Disk Access: add Terminal, Claude.app
- [ ] Accessibility: grant Rectangle, Raycast as they prompt
- [ ] Screen Recording: grant per app
- [ ] Camera / Microphone: grant per app

### Keyboard / Trackpad / Dock
- [ ] Restore your max key repeat speed
- [ ] Any Modifier Key remaps (e.g., Caps Lock → Ctrl)
- [ ] Trackpad: Tap to click, three-finger drag, etc.
- [ ] Dock: prune defaults, auto-hide if you like
- [ ] Menu Bar: Bluetooth, Wi-Fi, Battery %

### First-launch permissions
- [ ] Open Docker.app once — accepts the privileged helper prompt, daemon starts
- [ ] Open Rectangle.app, Raycast.app — grant Accessibility

## Verify (~3 min)

```bash
bash "/Volumes/T9 Files/mac-reset-backup/verify-setup.sh"
```

Read every ✗ and ! and resolve before declaring done.

## Cleanup (same week)

- [ ] Rotate any plaintext API keys that were in `.zshrc` — move them to a secret manager
- [ ] Revoke any old Dropbox / GitHub / etc. API tokens tied to the previous Mac
- [ ] Add a global gitignore (sample below)
- [ ] Verify Time Machine is targeting the same destination volume

### Sample global gitignore

```bash
mkdir -p ~/.config/git
cat > ~/.config/git/ignore <<'EOF'
.DS_Store
*.log
.env.local
.idea/
.vscode/
node_modules/
__pycache__/
*.pyc
EOF
git config --global core.excludesfile ~/.config/git/ignore
```

## When something goes wrong

### brew bundle fails on a cask
Comment the offending line, re-run, install manually after. Check `brew search <name>` for the right cask name.

### `gh auth login` won't work
```bash
gh auth login --hostname github.com --git-protocol https --web
```

### `ssh -T git@github.com` says "Permission denied"
```bash
ls -la ~/.ssh/id_*
chmod 600 ~/.ssh/id_*
# Also: gh ssh-key list — is the key registered?
```

### DMG won't mount
Disk Utility → File → Open Disk Image → select DMG → enter password

### Cowork tab is empty in Claude Desktop
See [`docs/02-cowork-recovery.md`](02-cowork-recovery.md) for the full APFS-snapshot recovery procedure.

### Finder hangs
```bash
killall fileproviderd
killall Finder
```
And turn OFF iCloud Desktop & Documents Sync if you'd enabled it.

### Last-resort full restore
System Settings → General → Transfer or Reset → Migration Assistant → from Time Machine backup. This brings back the entire pre-reset Mac, undoing your clean install. Only do this if something has gone catastrophically wrong.
