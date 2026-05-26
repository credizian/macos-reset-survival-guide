# 31 things that broke (or surprised me) during a 2026 macOS clean install

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

## More day-2 discoveries

### 24. Firefox 138+ "Profile Groups" silently supersedes `profiles.ini`
You restore your `Profiles/` directory and all of `profiles.ini`, launch Firefox, and the new built-in profile picker shows... only a "Create a profile" button. None of your restored profiles appear. The reason: Firefox 138+ added a **Profile Groups** system stored in SQLite at `~/Library/Application Support/Firefox/Profile Groups/<groupId>.sqlite`. The new picker reads from those databases — NOT from `profiles.ini`. Your pre-138 backup never had Profile Groups, so the new picker has no record of your profiles.

**Schema of `<groupId>.sqlite` `Profiles` table:**
```sql
CREATE TABLE Profiles (
  id INTEGER NOT NULL,
  path TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  avatar TEXT NOT NULL,
  themeId TEXT NOT NULL,
  themeFg TEXT NOT NULL,
  themeBg TEXT NOT NULL,
  PRIMARY KEY(id)
);
```

**Two-line fix** — write a `user.js` into your restored profile directories to disable the new picker entirely:
```bash
for prof in ~/Library/Application\ Support/Firefox/Profiles/*/; do
  echo 'user_pref("browser.profiles.enabled", false);' > "$prof/user.js"
done
```

Firefox falls back to the legacy `profiles.ini` behavior. Use `about:profiles` inside the browser to switch between them.

If `user.js` doesn't take effect on some builds (because the pref is checked before profile selection), the next-level fix is an Enterprise Policies file at `/Library/Application Support/Mozilla/distribution/policies.json` — that applies pre-profile-selection at the OS level.

### 25. GitHub Desktop persistence is split — Local Storage vs IndexedDB
Bulk-adding repos via the brew-installed `github` CLI shim works at first launch, but on next cold start of Desktop, your sidebar shows only ONE repo (the last one you selected). All other repos seem to have vanished.

The cause is GitHub Desktop's split storage:

| Location | What it stores |
|---|---|
| `Local Storage/leveldb/` | Account info, app version, **last-selected-repository-id**, feature flags |
| `IndexedDB/file__0.indexeddb.leveldb/` | The **actual repo list** — paths, remotes, last-fetched timestamps |

When Desktop cold-starts, it reads `last-selected-repository-id` from Local Storage and loads only that repo's metadata. The sidebar isn't re-populated from IndexedDB until something (manual UI add, sign-in event, refresh) triggers it.

**Fix:** the bulk-add works correctly when Desktop is **already running** during the loop. Each `github <path>` call sends an IPC message that triggers both an IndexedDB write AND a live sidebar update. Use a 1.5-second throttle so each repo's metadata fully settles before the next call:

```bash
# Launch GitHub Desktop and sign in FIRST. Then:
find ~/code -maxdepth 3 -name .git -type d | sed 's|/.git$||' | sort | \
  while read r; do
    github "$r"
    sleep 1.5
  done
```

Verification — peek at IndexedDB to count persisted repos without quitting Desktop:
```bash
IDB="$HOME/Library/Application Support/GitHub Desktop/IndexedDB/file__0.indexeddb.leveldb"
for f in "$IDB"/*; do strings "$f" 2>/dev/null; done | \
  grep -oE "/Users/$USER/<your-code-dir>/[a-zA-Z0-9_-]+" | sort -u | wc -l
```

---

## Day-3 wipe-day discoveries

Three days after the reset I returned the borrowed backup SSD. Verifying parity before wiping it revealed gaps the original "curated subset" migration silently missed.

### 26. Curated migration scripts have a blind spot — they don't sweep `~/` root
The original `export-credentials.sh` captured named subdirectories (`.ssh`, `.aws`, `.config`, specific app-state dirs). It did NOT capture the ~100 files that had accumulated at `~/` root over years — and the restore had no way to bring them back.

Comparing snapshot's `~/` to live `~/` via `comm -23` surfaced what was missing:
- **~17 private keys** (AWS instance `.pem`s, GitLab key, Oracle Cloud SSH key, Android `debug.keystore` + signing keystore, Teams keys)
- **SQL dumps** (4 production DB exports, total ~10 MB)
- **Cognito user-pool JSON export** (45 MB single file)
- **Python utility scripts** (delete-cog-dyn, delete-spam, account-summary)
- **~25 hidden AI tool config dirs** containing API keys / login state (`.cloudflared`, `.snowflake`, `.azure`, `.docker`, `.cursor`, `.codeium`, `.continue`, `.windsurf`, etc.)
- **Personal media** (mp3 recording, IMG_*, Outlook export docx + pdf)
- **Project dirs not under `~/code`** (`PycharmProjects`, `CascadeProjects`, `ses-templates`)

**Lesson:** any backup script needs a **catch-all flat sweep** of `~/` with an *exclude* list, not just an *include* list. Easier to enumerate what to skip (caches, package-manager dirs, models) than to remember every random file you've dropped in `~/` for the last 5 years.

The diff to find this kind of gap on YOUR machine:
```bash
comm -23 \
  <(ls -A /path/to/snapshot/Data/Users/$USER/ | sort) \
  <(ls -A ~/ | sort)
```

### 27. Desktop and Downloads get forgotten because they're "just clutter"
Default-untouched by curated backups, but contain one-off-but-irreplaceable items: LinkedIn data exports, employer pay slips, board meeting PDFs, downloaded credentials CSVs, certificate signing requests. ~45 MB across both folders for me, ~80 files — 95% junk and 5% irreplaceable.

Always include `~/Desktop` and `~/Downloads` in any pre-reset tar.

### 28. Tar exclude-list iteration — the silent bloat problem
My first home-folder tar attempt produced a **43 GB** archive instead of the expected ~2 GB. The culprits were three categories I forgot to exclude:

- **`a_code_project/`** — already on the live Mac + GitHub (verified earlier with HEAD + dirty-count parity check). Including it was pure duplication.
- **Package-manager caches**: `.npm`, `.yarn`, `.pnpm-store`, `.cache`, `.nvm`, `.pyenv`, `.rustup`, `.cargo`, `.m2`, `.ivy2`, `.sbt`, `.cocoapods`, `.bun`. All regen-on-demand.
- **Tool internal state subdirs** named `Cache`, `Code Cache`, `CachedData`, `GPUCache`, `IndexedDB`, `Local Storage`, `Service Worker`. Common to every Electron app + many AI tools.

After adding those to `--exclude`, the archive dropped to **3.8 GB** — same content fidelity, no useful loss. Repeated iteration was the actual cost: every wrong attempt wastes ~5-10 min on USB-SSD read.

**Pattern**: AI tool dirs (`.cursor`, `.windsurf`, `.codeium`, `.continue`, `.augment`, `.qoder`, `.trae`, `.kiro`, `.codex`, `.warp`, plus ~15 others) are typically 95% cache wrapping 5% real config. If you're skeptical, exclude the whole tool dir — login + re-config on the new machine is 30 seconds per tool.

### 29. SSD "secure erase" is cryptographic, not physical
Multi-pass overwrites on SSDs are theater because wear-leveling maps logical writes to different physical cells than the ones holding your old data. macOS Disk Utility's "Security Options" on a USB SSD greys out everything except "Fastest" — and **that's the correct option**.

Real SSD wipe = one of:
- **Drop the encryption key** (instant) — only works if volume was encrypted-at-rest
- **TRIM the entire volume** (drive does it internally after format)
- **Paranoid extra**: fill the new empty volume with `/dev/urandom` to force fresh writes that exercise wear-leveling against every cell

```bash
dd if=/dev/urandom of=/Volumes/<name>/junk.bin bs=1m
# Runs ~15-30 min on 1 TB USB-C SSD, ends with "No space left" (expected)
rm /Volumes/<name>/junk.bin
```

### 30. Time Machine destinations must be removed BEFORE wiping
If your backup volume is registered as a TM destination, erasing it leaves `tmutil` with a phantom reference that errors on every backup attempt. Clear it cleanly first:

```bash
tmutil destinationinfo                              # find the ID
sudo tmutil removedestination <DESTINATION-UUID>   # unregister it
```

If destination shows "No destinations configured" already → you're fine (TM noticed it disappeared when you ejected the drive).

### 31. APFS snapshots on TM destinations: path structure varies by snapshot age
On the same backup volume, two snapshots from different dates can have different internal structure:

```bash
# Newer (post-Sequoia TM schema):
/snap-mount/<date>.backup/Macintosh HD - Data/Users/$USER/...

# Older (pre-Sequoia or different TM version):
/snap-mount/<date>.backup/Data/Users/$USER/...
```

Always `ls` the snapshot's `<date>.backup/` first to confirm which schema you're dealing with. Don't assume — I burned 5 min on a "No such file or directory" when an older snapshot used the shorter path.

Also: read-only snapshot mounts with `noowners` flag work without sudo as long as file permissions allow your UID to read. If your first `tar` attempt with sudo creates a root-owned archive, the non-sudo retry can't overwrite it cleanly. Test read access with a simple `cat <one-file>` before deciding sudo is needed:

```bash
cat /snap-mount/.../Users/$USER/some-file && echo "no sudo needed"
```

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
