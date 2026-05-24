# 23 things that broke (or surprised me) during a 2026 macOS clean install

These are in roughly the order I hit them. Each one cost me anywhere from 30 seconds to an hour. Capturing them so you don't have to repeat the journey.

---

## Restore script bugs

### 1. MySQL Workbench's data dir is `MySQLWorkbench` — one word, no slash
The Application Support dir is `~/Library/Application Support/MySQLWorkbench/` (one word). A natural-looking path like `~/Library/Application Support/MySQL/Workbench/` is what my first restore script wrote to — and MySQL Workbench then found no saved connections because it doesn't look there.

**Fix:** `cp -R $SRC/MySQL-Workbench/. ~/Library/Application\ Support/MySQLWorkbench/`

### 2. The "MySQL Workbench" cask is `mysqlworkbench` — no dash either
`brew install --cask mysql-workbench` fails: that cask doesn't exist. Brew suggests `mysqlworkbench`. Easy to grep-and-replace once you know.

### 3. `awscli` was missing from my Brewfile entirely
`aws sts get-caller-identity` failed with "command not found" because I had AWS creds restored but no CLI installed. Simple omission — add `brew "awscli"`.

### 4. `brew bundle install`'s npm step runs without `node@24` on PATH
Every `npm "<pkg>"` line failed with `env: node: No such file or directory`. The fix is one line of context: brew bundle shells out via `env`, which doesn't inherit your interactive `.zshrc` PATH. The patch:
```bash
export PATH="/opt/homebrew/opt/node@24/bin:$PATH"
brew bundle install --file=Brewfile
```

### 5. Raycast's encrypted DBs from old Mac → "Database Exception" on new Mac
Raycast stores chat/activity data in SQLite databases encrypted-at-rest with a key from your **old Mac's Keychain**. Keychain doesn't migrate across a clean install, so on the new Mac those files are unreadable. Raycast shows a "Database Exception" dialog with a Reset button.

**Fix:** exclude `raycast-enc.sqlite*` and `raycast-activities-enc.sqlite*` from the restore. Let Raycast re-init fresh, then sign into cloud sync to recover config.

### 6. `~/.ssh/config` needs `IgnoreUnknown UseKeychain` at GLOBAL scope
Homebrew's openssh (`/opt/homebrew/bin/ssh`) doesn't recognize the `UseKeychain` directive that Apple's openssh accepts. If `IgnoreUnknown UseKeychain` is buried inside a `Host` block, Homebrew openssh **fails to parse the entire file**, breaking all SSH-related tools. It must be at the global scope, before any `Host` block.

### 7. No GitHub host key in `known_hosts` on a fresh Mac
First `ssh -T git@github.com` fails with "Host key verification failed". Fix: pre-populate against GitHub's published fingerprints:
```bash
ssh-keyscan -t ed25519,ecdsa,rsa github.com >> ~/.ssh/known_hosts
```
GitHub's fingerprints are documented and stable; this is safe to automate.

### 8. GitHub Desktop's repo list doesn't migrate — but brew installs a CLI shim
The app stores its repo list in LevelDB (machine-specific lock files) and auth in Keychain. Neither survives a reset. But `brew install --cask github` installs both the app and a CLI shim at `/opt/homebrew/bin/github`. Loop the shim over your code dir to bulk-add:
```bash
find ~/code -maxdepth 3 -name .git -type d | sed 's|/.git$||' | \
  while read r; do github "$r"; sleep 0.3; done
```
The `sleep 0.3` is important — Desktop's IPC handler drops messages under burst.

### 9. macOS rsync is too old for `--info=progress2`
The system `rsync` is BSD-derived and predates several useful flags. If you want progress output, `brew install rsync` or just drop the flag.

### 10. Dropbox preserves stale `.git/*.lock` files from pre-reset operations
If you keep any git repo under Dropbox, you may find `.git/index.lock`, `.git/HEAD.lock`, `.git/objects/maintenance.lock` files dated weeks earlier — relics of operations interrupted before they could clean up. They block `git commit` with "Another git process seems to be running". Sweep them:
```bash
find ~/Dropbox -name "*.lock" -type f -path "*/.git/*" -delete
```

---

## Reset-day surprises

### 11. `mas` silently skips entries if you're not signed into the App Store
`brew bundle install` doesn't error — every `mas "App Name"` line just no-ops. Sign in via System Settings → Apple ID → Media & Purchases **before** running brew bundle.

### 12. `mas account` is deprecated post-Catalina
You can't programmatically verify App Store sign-in anymore. Workaround: if `mas list` returns anything, you're signed in.

### 13. `gh auth login` doesn't grant the scopes needed to push SSH keys
`gh ssh-key add` requires the `admin:public_key` scope, which `gh auth login` doesn't ask for. You need a second step:
```bash
gh auth refresh -h github.com -s admin:public_key
```
Browser device-flow re-auth. After this, `gh ssh-key add ~/.ssh/id_ed25519.pub` works.

### 14. Some AI tool shell-out features can leak passphrases
If you let an AI assistant shell out a command via a prefix-based shell tool, and that command prompts for a passphrase, the prompt may not get TTY input — and the user's typed passphrase ends up as the next chat message instead. **Always run `ssh-add` directly in Terminal.app**, never through an AI tool's shell-out.

### 15. `docker-desktop` cask fails without sudo pre-creating `/usr/local/cli-plugins`
The cask post-install needs to create that directory and brew can't prompt for sudo non-interactively. The fix is two lines in your restore script, before `brew bundle install`:
```bash
sudo mkdir -p /usr/local/cli-plugins
sudo chown $USER /usr/local/cli-plugins
```

---

## The Cowork recovery saga

### 16. Claude Desktop / Cowork data isn't in any standard backup
The data lives at `~/Library/Application Support/Claude/local-agent-mode-sessions/` — outside the usual `~/.config` or "Library/Application Support/{App}" patterns most backup scripts cover. If you don't explicitly back it up, a reset wipes your Cowork chats, scheduled tasks, projects, and routine run history.

### 17. `tmutil listbackups` shows phantom paths after a reset
On a freshly-set-up Mac with an existing TM destination, `tmutil listbackups` will list pre-reset snapshots — but `ls /Volumes/.timemachine/<UUID>/<date>.backup/` returns "No such file or directory". macOS is caching backup metadata via `com.apple.TimeMachine.inheritance.plist`, but inheritance is a logical machine-ID remapping; it doesn't preserve physical snapshot data.

### 18. Pre-reset backups *do* exist — as APFS snapshots inside the backup volume
The `.previous` directory you see at the root of the TM destination is only the **most recent** backup mounted as a filesystem. Older backups exist as **APFS snapshot objects** inside the volume's APFS container. Find them:
```bash
diskutil apfs listSnapshots disk5s2   # the device identifier of your TM backup volume
```

### 19. Mounting an APFS snapshot needs `sudo mount_apfs`
The snapshots aren't auto-mounted; you have to mount them manually:
```bash
sudo mkdir -p /tmp/tm-snap
sudo mount_apfs -o nobrowse,ro,noowners \
  -s com.apple.TimeMachine.<DATE>.backup \
  /dev/disk5s2 /tmp/tm-snap
```
Flags worth knowing:
- `ro` = read-only (you can't accidentally damage the snapshot)
- `noowners` = ignore stored UIDs (lets you read across user ID changes)
- `-s <snapshot-name>` = pick which snapshot

This is documented in `man mount_apfs` but doesn't surface in Apple's user-facing docs.

### 20. Stable account UUIDs save the day for Cowork recovery
Inside `local-agent-mode-sessions/`, the path is `<account-uuid>/<sub-uuid>/<session-data>`. After signing into the new Mac's Claude Desktop, **both UUIDs match the old Mac** — Anthropic uses stable account-tied UUIDs, not per-device random ones. The recovery is a copy, not a rename.

### 21. `ditto` fails on macOS deny ACLs that even root can't bypass
`ditto $OLD $NEW` is the canonical macOS preserve-everything copy tool — but it fails on the nested `.claude/projects/<hash>/<msg-uuid>.jsonl` chat transcripts. Why? The destination dirs from a partial earlier copy have ACLs like:
```
group:everyone deny add_file,delete,add_subdirectory,delete_child,writeattr,writeextattr,chown
```
ACLs override Unix permissions even for file owners. ditto's attempt to preserve those ACLs onto the destination causes write failures.

**Working approach:**
```bash
chmod -RN <dest>   # strip ACLs from destination
rsync -rlt --ignore-errors --no-perms --no-owner --no-group \
  --chmod=u+rwX,go-rwx <src>/ <dest>/
```

### 22. iCloud Drive's "Optimize Storage" leaves 0-byte placeholders
Your `~/Documents` may look mostly empty in a TM snapshot — because iCloud Documents Sync stores files only in the cloud with 0-byte local placeholder files. TM backs up the placeholders, not the content.

**Fallback:** macOS creates `~/iCloud Drive (Archive)/` when you disable iCloud Documents Sync. This Archive contains the actual content of files that had been previously downloaded locally. Pure-cloud files are only recoverable by signing back into iCloud.

### 23. Renaming `remoteToolsDeviceName` doesn't claim orphan Cowork data
Tempting hypothesis: maybe Cowork data is keyed off the device name in `claude_desktop_config.json`, and renaming the new Mac to match the old (`mac-attlocal-net` or whatever) makes the data appear. **It doesn't.** The data binding is via the account UUID inside `local-agent-mode-sessions/`. Don't rename the device — copy the data.

---

## Time to productive

After incorporating these fixes back into the scripts, a fresh reset is about **75 minutes hands-on**:

- 5 min pre-flight (sign out of iCloud / iMessage / FaceTime / App Store, T9 plugged in, password confirmed)
- 10 min erase + reinstall
- 10 min Setup Assistant
- 25-30 min restore.sh runs (mostly waiting on brew bundle + rsync)
- 15-20 min sign-ins (iCloud, Slack, ClickUp, VS Code Sync, etc.)
- 5 min verify-setup.sh review

Productive on code after ~50 minutes. Fully clean ~75.
