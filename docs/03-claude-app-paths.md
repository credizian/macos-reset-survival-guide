# Claude Desktop — what to back up, what to skip

Claude Desktop is cloud-first for chats, but has a surprising amount of local state. Here's the map.

## Path inventory

All paths under `~/Library/Application Support/Claude/`:

| Path | Size | Back up? | Why |
|---|---|---|---|
| `local-agent-mode-sessions/` | varies | **YES** | Cowork chats, scheduled tasks, projects, agent state. **Local only — not in any cloud.** |
| `claude_desktop_config.json` | ~10 KB | **YES** | Trusted folders list, Chrome extension pairing, browser permissions, per-folder permission acks, keyboard shortcuts |
| `Claude Extensions/` | varies | **YES** | Installed MCP servers + extension bundles (170+ MB for AWS API MCP alone) |
| `Claude Extensions Settings/` | small | **YES** | Per-extension config |
| `extensions-installations.json` | small | **YES** | Manifest of installed extensions |
| `cowork-enabled-cli-ops.json` | tiny | YES | Cowork feature flag state |
| `git-worktrees.json` | small | YES | Claude Code worktree state |
| `window-state.json` | tiny | optional | UI window positions; cosmetic |
| `bridge-state.json` | small | optional | Claude in Chrome bridge state |
| `config.json` | ~4 KB | **NO** | Has OAuth tokens tied to the OLD device. New install will create fresh ones — don't overwrite. |
| `vm_bundles/` | 12 GB | **NO** | Electron VM bundles for code execution. Regenerable. Will rebuild on first use. |
| `Cache/` | varies | **NO** | Chromium HTTP cache |
| `Code Cache/` | varies | **NO** | Same |
| `GPUCache/` `DawnGraphiteCache/` `DawnWebGPUCache/` | varies | **NO** | Graphics caches |
| `IndexedDB/` | small | **NO** | Cached cloud data — resyncs on sign-in |
| `Local Storage/leveldb/` | small | **NO** | Same |
| `Cookies` `Cookies-journal` | small | **NO** | You'll re-sign-in anyway |
| `Session Storage/` | small | **NO** | Per-tab session state, transient |
| `Crashpad/` | varies | **NO** | Crash reports |
| `DIPS` `DIPS-wal` | small | **NO** | Bounce-tracking mitigation database, auto-rebuilds |
| `Network Persistent State` | small | **NO** | HTTPS connection metadata |
| `extensions-blocklist.json` | small | **NO** | Server-managed blocklist, refreshes on its own |

Plus, outside Application Support:

| Path | Back up? | Why |
|---|---|---|
| `~/Documents/Claude/Projects/` | **YES** | Project files referenced by Cowork chats (the "Show in Folder" button needs these) |
| `~/Documents/Claude/Scheduled/` | **YES** | SKILL.md files for scheduled tasks |
| macOS Keychain entries for "Anthropic" | not portable | Migrate via sign-in — Keychain doesn't survive a reset by design |

## Quick backup snippet

```bash
APPSUP="$HOME/Library/Application Support"
CLAUDE_APP="$APPSUP/Claude"
STAGING="/path/to/your/backup/staging"

mkdir -p "$STAGING/Claude"

# Critical data
[ -d "$CLAUDE_APP/local-agent-mode-sessions" ] && \
  cp -R "$CLAUDE_APP/local-agent-mode-sessions" "$STAGING/Claude/"

# Config files (skip config.json)
for f in claude_desktop_config.json extensions-installations.json \
         cowork-enabled-cli-ops.json git-worktrees.json window-state.json \
         bridge-state.json; do
  [ -f "$CLAUDE_APP/$f" ] && cp "$CLAUDE_APP/$f" "$STAGING/Claude/"
done

# Extensions
[ -d "$CLAUDE_APP/Claude Extensions" ] && \
  cp -R "$CLAUDE_APP/Claude Extensions" "$STAGING/Claude/"
[ -d "$CLAUDE_APP/Claude Extensions Settings" ] && \
  cp -R "$CLAUDE_APP/Claude Extensions Settings" "$STAGING/Claude/"

# Project files referenced by chats
[ -d ~/Documents/Claude ] && cp -R ~/Documents/Claude "$STAGING/Documents-Claude"
```

## Quick restore snippet

```bash
CLAUDE_APP="$HOME/Library/Application Support/Claude"
BACKUP="/path/to/your/backup"

mkdir -p "$CLAUDE_APP"

# IMPORTANT: Claude.app must be quit. Cmd+Q the app first.

# Sessions
[ -d "$BACKUP/Claude/local-agent-mode-sessions" ] && \
  rsync -a "$BACKUP/Claude/local-agent-mode-sessions/" \
           "$CLAUDE_APP/local-agent-mode-sessions/"

# Config (preserves OLD's trusted folders + extensions list, keeps NEW device name)
python3 -c "
import json
with open('$BACKUP/Claude/claude_desktop_config.json') as f: old = json.load(f)
with open('$CLAUDE_APP/claude_desktop_config.json') as f: new = json.load(f)
merged = old.copy()
merged['preferences']['remoteToolsDeviceName'] = new['preferences']['remoteToolsDeviceName']
for k, v in new['preferences'].items():
    if k not in merged['preferences']:
        merged['preferences'][k] = v
with open('$CLAUDE_APP/claude_desktop_config.json', 'w') as f:
    json.dump(merged, f, indent=2)
"

# Extensions
rsync -a "$BACKUP/Claude/Claude Extensions/" "$CLAUDE_APP/Claude Extensions/"
rsync -a "$BACKUP/Claude/Claude Extensions Settings/" "$CLAUDE_APP/Claude Extensions Settings/"
cp "$BACKUP/Claude/extensions-installations.json" "$CLAUDE_APP/extensions-installations.json"

# Project files
mkdir -p ~/Documents/Claude
rsync -a "$BACKUP/Documents-Claude/" ~/Documents/Claude/
```

## Account UUIDs are stable across devices

Inside `local-agent-mode-sessions/` the directory structure is `<account-uuid>/<sub-uuid>/...`. After signing into Claude Desktop on a new Mac, both UUIDs will be **identical** to your old Mac (assuming same Anthropic account). This is convenient for restoration — you don't have to rename anything.

If Anthropic changes this in the future, the recovery pattern would be:
```bash
# Move old data into new UUID dir before copying
mv $OLD_UUID/$OLD_SUB $NEW_UUID/$NEW_SUB
```

## Notes on `remoteToolsDeviceName`

This field in `claude_desktop_config.json` is just a display name for "which device am I" — used in the cloud UI to disambiguate multiple paired devices. Changing it on the new Mac does NOT cause it to claim orphan data from an old device-name. The data binding is via account UUID, not device name. (Tested empirically; renaming did nothing.)
