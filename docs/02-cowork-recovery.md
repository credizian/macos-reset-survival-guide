# Recovering Claude Desktop / Cowork data from a Time Machine snapshot

> "I wiped my Mac and my Cowork tab is empty. Is my data gone?"

Probably not — but it's in a place macOS doesn't easily surface. This is the step-by-step recovery.

## What you're recovering

Claude Desktop stores Cowork chats, scheduled tasks, projects, and agent state at:

```
~/Library/Application Support/Claude/local-agent-mode-sessions/<account-uuid>/<sub-uuid>/
```

This directory contains:
- `local_<session-uuid>.json` — metadata + summary per chat (200+ on an active account)
- `local_<session-uuid>/` — per-session workspace with `audit.jsonl` (the transcript), uploaded files, agent state
- `cowork_settings.json`, `cowork_plugins/` — Cowork app settings + plugin configs
- `agent/`, `debug/`, `spaces/` — runtime state, debug logs, projects

None of this is in iCloud or any Anthropic-side backup. It's local-only. If you wiped your Mac without preparing, your only hope is Time Machine.

## Why the data appears "gone"

When you sign into Claude Desktop on a new Mac, it creates an empty version of this directory structure with the **same account UUIDs as your old Mac** (stable, account-tied). The Cowork tab reads from this directory — empty dir, empty Cowork. The actual data is sitting on your TM backup, but mac OS doesn't auto-recover it for you.

## What you need

- The same external SSD or NAS you were using as the TM destination
- Full Disk Access granted to Terminal (System Settings → Privacy & Security → Full Disk Access → enable Terminal)
- About 10 minutes

## Step 1: Find the pre-reset snapshot

`tmutil listbackups` will lie to you here — it shows paths that don't physically exist, due to a logical machine-ID inheritance mapping. Trust APFS instead:

```bash
# Find the device identifier of your TM backup volume
diskutil info /Volumes/<your-tm-volume-name> | grep "Device Identifier"
# example output: Device Identifier: disk5s2

# List all APFS snapshots on that volume
diskutil apfs listSnapshots disk5s2
```

You'll see entries like:
```
+-- 4106393C-8C6C-47DA-B966-0B5CD4D6DA6F
|   Name:        com.apple.TimeMachine.2026-05-22-224811.backup
|   XID:         12940
|   Purgeable:   Yes
```

Find the most recent snapshot dated **before** your reset.

## Step 2: Mount it read-only

APFS snapshots aren't auto-mounted. Use `mount_apfs`:

```bash
sudo mkdir -p /tmp/tm-snap
sudo mount_apfs -o nobrowse,ro,noowners \
  -s com.apple.TimeMachine.2026-05-22-224811.backup \
  /dev/disk5s2 /tmp/tm-snap
```

What the flags do:
- `ro` — read-only, so you can't accidentally damage the snapshot
- `noowners` — ignore stored UID/GID, so you can read files owned by the "old you"
- `nobrowse` — doesn't pollute Finder's sidebar
- `-s <name>` — which snapshot to mount

After mount, the data is at:
```
/tmp/tm-snap/<date>.backup/Data/Users/<username>/Library/Application Support/Claude/local-agent-mode-sessions/
```

## Step 3: Quit Claude Desktop completely

This matters — if Claude.app is running, it'll overwrite your restored files with the in-memory empty state when it next quits. Cmd+Q the app. Verify it's actually quit:

```bash
pgrep -lf "Claude.app" | grep -v chrome-native
# (should print nothing)
```

The Chrome Extension's native messaging host is a separate process and doesn't interfere — only check for the main `Claude.app` process.

## Step 4: Strip destination ACLs

If you've launched Claude.app and signed in on the new Mac, the destination dirs already have macOS ACLs that include:
```
group:everyone deny add_file,delete,delete_child,writeattr,writeextattr,chown
```

These ACLs apply even to the file owner (you). `cp`, `ditto`, and `rsync --xattrs` will all fail with permission errors when trying to write into them. Strip them:

```bash
NEW="$HOME/Library/Application Support/Claude/local-agent-mode-sessions"
chmod -RN "$NEW/"*/*/
```

`chmod -RN` removes all ACLs recursively. The Unix-permission file ownership stays the same.

## Step 5: Copy with `rsync` — but NOT with `ditto`

`ditto` will partially fail on these files (it tries to preserve ACLs and triggers the deny rules). `rsync` works if you tell it NOT to preserve anything fancy:

```bash
OLD="/tmp/tm-snap/<date>.backup/Data/Users/<username>/Library/Application Support/Claude/local-agent-mode-sessions/<account-uuid>/<sub-uuid>"
NEW="$HOME/Library/Application Support/Claude/local-agent-mode-sessions/<account-uuid>/<sub-uuid>"

rsync -rlt --ignore-errors --no-perms --no-owner --no-group \
  --chmod=u+rwX,go-rwx "$OLD/" "$NEW/"
```

Flag breakdown:
- `-r -l -t` — recursive, preserve symlinks + times. No `-a` (which would imply preserve owners/perms/etc.)
- `--ignore-errors` — don't bail on any single-file failure
- `--no-perms --no-owner --no-group` — explicit "don't carry source metadata over"
- `--chmod=u+rwX,go-rwx` — force perms to be user-read-write, capital `X` so it sets exec on dirs only

## Step 6: Copy the top-level loose JSON files

`rsync` may skip the top-level `local_<uuid>.json` files due to in-flight permission errors mid-traversal. Just copy them directly:

```bash
find "$OLD" -maxdepth 1 -type f -print0 | \
  xargs -0 -I {} cp -p {} "$NEW/"
```

## Step 7: Clean up rsync's leftover temp files

rsync writes to `.BC.T_<hash>` temp files before renaming to the final name. If it crashed mid-copy, you'll have these strewn around:

```bash
find "$NEW" -name ".BC.T_*" -type f -delete
```

## Step 8: Restore `~/Documents/Claude`

Cowork chats reference files at `~/Documents/Claude/Projects/...`. The chat text loads fine, but "Show in Folder" on file artifacts shows "Failed to load local file" unless these are restored.

If you had iCloud Documents Sync ON before:

```bash
SNAP_ICLOUD="/tmp/tm-snap/<date>.backup/Data/Users/<username>/iCloud Drive (Archive)/Documents/Documents - <hostname>/Claude"
mkdir -p ~/Documents/Claude
rsync -a --no-perms --no-owner --no-group "$SNAP_ICLOUD/" ~/Documents/Claude/
```

(Note: only files that had been downloaded locally before reset will be in the Archive. Pure-cloud files need iCloud sign-in.)

## Step 9: Optional — merge `claude_desktop_config.json`

If you want your old config (trusted folders, browser permissions, extension settings, per-folder permission acks):

```python
import json

with open(OLD_CFG) as f: old = json.load(f)
with open(NEW_CFG) as f: new = json.load(f)

merged = old.copy()
# Keep new device name (don't try to claim orphan data via rename — doesn't work)
merged['preferences']['remoteToolsDeviceName'] = new['preferences']['remoteToolsDeviceName']
# Carry forward any new keys from new -> merged
for k, v in new['preferences'].items():
    if k not in merged['preferences']:
        merged['preferences'][k] = v

with open(NEW_CFG, 'w') as f:
    json.dump(merged, f, indent=2)
```

## Step 10: Restore Claude Extensions

Extension bundles + their settings, if you had MCP servers installed:

```bash
SNAP_CLAUDE="/tmp/tm-snap/<date>.backup/Data/Users/<username>/Library/Application Support/Claude"
CUR_CLAUDE="$HOME/Library/Application Support/Claude"

# Extension bundles
rsync -av "$SNAP_CLAUDE/Claude Extensions/" "$CUR_CLAUDE/Claude Extensions/"
# Per-extension settings
rsync -av "$SNAP_CLAUDE/Claude Extensions Settings/" "$CUR_CLAUDE/Claude Extensions Settings/"
# Manifest
cp "$SNAP_CLAUDE/extensions-installations.json" "$CUR_CLAUDE/extensions-installations.json"
```

## Step 11: Unmount and relaunch

```bash
sudo umount /tmp/tm-snap
```

Then open Claude Desktop. Cowork tab populates, chats open with transcripts, projects appear, scheduled tasks return.

## What this technique doesn't recover

- Past run logs that Cowork displays in the cloud (those are server-side and may have a retention window)
- Conversations that were created in the gap between your last TM snapshot and the reset
- iCloud-only project files (no on-device copy → not recoverable without re-syncing)
- Anything specifically encrypted with a key from the old Mac's Keychain (Raycast does this; Claude Desktop doesn't)

## Preventing the problem next time

Add this to your pre-reset backup script:

```bash
APPSUP="$HOME/Library/Application Support"
CLAUDE_APP="$APPSUP/Claude"

# The critical data
cp -R "$CLAUDE_APP/local-agent-mode-sessions" "$STAGING/app-state/Claude/"

# Config + extensions
for f in claude_desktop_config.json extensions-installations.json \
         cowork-enabled-cli-ops.json git-worktrees.json; do
  [ -f "$CLAUDE_APP/$f" ] && cp "$CLAUDE_APP/$f" "$STAGING/app-state/Claude/"
done
cp -R "$CLAUDE_APP/Claude Extensions" "$STAGING/app-state/Claude/"
cp -R "$CLAUDE_APP/Claude Extensions Settings" "$STAGING/app-state/Claude/"

# Project files referenced by chats
[ -d ~/Documents/Claude ] && cp -R ~/Documents/Claude "$STAGING/app-state/Documents-Claude"
```

DON'T include:
- `config.json` — has OAuth tokens; will be recreated cleanly on sign-in
- `vm_bundles/` — 12 GB of regenerable Electron containers
- `Cache/`, `GPUCache/`, `Code Cache/` — Chromium caches
- `IndexedDB/`, `Local Storage/` — cached cloud data that resyncs

The full restore-side handling is in [`scripts/restore.sh`](../scripts/restore.sh).
