# Wiping the old backup drive — without losing data the migration missed

The reset went fine. Two days later you reach for the backup SSD to wipe and return it. Before you click Erase: there is almost certainly content on that drive that your "successful" restore quietly skipped. This doc is the procedure for finding and rescuing those gaps before the wipe.

## Why this matters

Curated migration scripts (like the `export-credentials.sh` in this repo) protect *named* subdirectories — `.ssh`, `.aws`, app data dirs, dotfiles. They don't sweep `~/` root, and they don't enumerate the dozens of hidden tool dirs that accumulate over years (`.cursor`, `.snowflake`, `.cloudflared`, etc.).

When I ran the comparison on day 3, the snapshot's `~/` had ~100 files that didn't exist on live Mac — including 17 private keys, 5 SQL dumps, a 45 MB Cognito user-pool export, and ~25 AI-tool config dirs holding API credentials.

If I had wiped the drive without checking, all of it would be gone forever.

---

## Step 1 — Inventory the visible content (10 min)

The backup drive has two kinds of content:

1. **Visible files** in the volume root (`mac-reset-backup/`, code mirror, DMGs)
2. **APFS Time Machine snapshots** — pre-reset Mac state, invisible to `ls`, takes most of the disk

Check both:

```bash
# Visible content of the backup data volume
ls -la "/Volumes/<your-backup-data-volume>/"
du -sh "/Volumes/<your-backup-data-volume>/"*

# APFS snapshots (the hidden bulk)
diskutil apfs listSnapshots disk5s2
```

Most of the disk usage you can't see in Finder is the snapshots. They're the **only** place pre-reset home folder state still exists once you've moved on with the new Mac.

---

## Step 2 — Verify the visible files are redundant (10 min)

For each visible directory on the backup drive, prove it's already on the live Mac (or in GitHub):

### Code mirror parity
For every repo in `a_code_project/` (or your code dir), compare HEAD + dirty file count:

```bash
for r in /Volumes/<backup>/code/*/; do
  r="${r%/}"; name=$(basename "$r")
  live="$HOME/code/$name"
  [ -d "$live/.git" ] || { echo "$name: MISSING on live"; continue; }
  bk_head=$(git -C "$r" rev-parse HEAD | head -c 7)
  lv_head=$(git -C "$live" rev-parse HEAD | head -c 7)
  bk_dirty=$(git -C "$r" status --porcelain | wc -l | tr -d ' ')
  lv_dirty=$(git -C "$live" status --porcelain | wc -l | tr -d ' ')
  [ "$bk_head" = "$lv_head" ] && [ "$bk_dirty" = "$lv_dirty" ] \
    && echo "$name: ✓ match" \
    || echo "$name: ✗ diverged (backup=$bk_head/$bk_dirty live=$lv_head/$lv_dirty)"
done
```

Anything marked `MISSING` or `diverged` and where the **backup is newer** → uncommitted work. Pull it before wiping.

### Encrypted DMG parity
If your backup includes encrypted DMG bundles (e.g. `mac-migration.dmg` with credentials), mount each read-only and diff key files:

```bash
hdiutil attach -readonly -nobrowse "/Volumes/<backup>/mac-migration.dmg"
# Compare specific files between mounted DMG and live Mac
diff -q /Volumes/MacMigration/credentials/ssh/config ~/.ssh/config
diff -q /Volumes/MacMigration/credentials/aws/credentials ~/.aws/credentials
hdiutil detach /Volumes/MacMigration
```

When live is **newer** (e.g. `known_hosts` grew, `.ssh/config` was patched), that's the signature of a successful restore — the DMG is superseded.

---

## Step 3 — Check the snapshot for what the curated backup missed (10 min)

This is the step that catches the migration's blind spot.

```bash
# Mount the most recent pre-reset snapshot
sudo mkdir -p /tmp/snap-mount
diskutil apfs listSnapshots disk5s2     # find latest pre-reset
sudo mount_apfs -o nobrowse,ro,noowners \
  -s "com.apple.TimeMachine.YYYY-MM-DD-HHMMSS.backup" /dev/disk5s2 /tmp/snap-mount

# Schema varies — check whether it's "Macintosh HD - Data" or just "Data"
ls /tmp/snap-mount/*.backup/

# Set SNAPHOME accordingly
SNAPHOME="/tmp/snap-mount/<date>.backup/<Data-or-Macintosh HD - Data>/Users/$USER"

# Find ~/ root files that exist on snapshot but NOT on live
comm -23 <(ls -A "$SNAPHOME" | sort) <(ls -A ~/ | sort)

# Also spot-check Desktop / Downloads (commonly empty post-reset)
du -sh "$SNAPHOME/Desktop/" "$SNAPHOME/Downloads/"
ls -la "$SNAPHOME/Desktop/" "$SNAPHOME/Downloads/" | head -40
```

Categorize the `comm` output:
- **Critical**: `*.pem`, `*.key`, `*.keystore`, `gitlab*` — private keys
- **Important**: `*.sql`, `*.json` data exports, custom scripts, `.cloudflared/`, `.snowflake/`, `.azure/`, `.docker/` (auth state)
- **Personal**: media files, downloaded docs (linkedin exports, pay slips, etc.)
- **Skip**: `node_modules/`, `venv/`, `.npm/`, `.ollama/`, `.gradle/`, `.cache/`, `Library/` (already restored or pure cache)

---

## Step 4 — Archive what you'll lose, exclude what you don't need (15 min)

A single tar.gz with the right excludes captures the irreplaceable in ~2-5 GB:

```bash
SNAP="/tmp/snap-mount/<date>.backup/<Data-or-Macintosh HD - Data>/Users/$USER"
OUT="$HOME/Dropbox/backups/pre-reset-home-root-$(date +%F).tar.gz"
mkdir -p "$(dirname "$OUT")"

cd "$SNAP" && tar -czvf "$OUT" \
  --exclude='a_code_project' \
  --exclude='Library' --exclude='node_modules' --exclude='venv' \
  --exclude='.ollama' --exclude='.gradle' --exclude='.konan' \
  --exclude='.virtualenvs' --exclude='.gem' --exclude='nltk_data' \
  --exclude='.npm' --exclude='.yarn' --exclude='.pnpm-store' \
  --exclude='.cache' --exclude='.nvm' --exclude='.pyenv' \
  --exclude='.rustup' --exclude='.cargo' --exclude='.m2' --exclude='.ivy2' \
  --exclude='.sbt' --exclude='.cocoapods' --exclude='.bun' \
  --exclude='Cache' --exclude='Code Cache' --exclude='CachedData' \
  --exclude='GPUCache' --exclude='Crashpad' --exclude='blob_storage' \
  --exclude='Service Worker' --exclude='Session Storage' \
  --exclude='Local Storage' --exclude='IndexedDB' \
  --exclude='avd' --exclude='build-cache' \
  --exclude='.DS_Store' --exclude='.Trash' \
  .

# Verify integrity
gunzip -t "$OUT" && echo "✓ archive valid"
ls -lh "$OUT"
```

**Why this exclude list works:** it skips package-manager caches (regen-on-demand), tool-internal Electron caches, the Library tree (already restored from DMG), and `a_code_project/` (already on live + GitHub). Everything else — keys, dumps, scripts, personal docs, hidden tool configs with creds — is kept.

**Spot-check keys made it:**
```bash
tar -tzf "$OUT" | grep -E '\.pem$|\.key$|keystore$|gitlab' | sort
```

---

## Step 5 — Remove the Time Machine destination

If the backup volume was registered as a TM destination, clear that registration before erasing the volume — otherwise `tmutil` will keep trying to back up to a vanished device:

```bash
tmutil destinationinfo                          # get the destination ID
sudo tmutil removedestination <DESTINATION-ID>
```

If `destinationinfo` already says "No destinations configured" — TM noticed when you ejected. Skip ahead.

---

## Step 6 — Wipe via Disk Utility

For SSDs, **the simple Disk Utility erase IS the secure erase**. Multi-pass overwrites are theater on SSDs because wear-leveling silently maps logical writes to different physical cells than the ones holding old data. Disk Utility's "Security Options" pane on an SSD greys out everything except "Fastest" — and that's correct.

1. In Finder sidebar: right-click each volume on the backup drive → **Eject** (keep drive plugged in).
2. Open **Disk Utility** → **View → Show All Devices** (top-left dropdown — critical).
3. In sidebar, click the **physical drive at the top** (something like "Samsung Portable SSD T9 Media"), NOT the individual volumes.
4. Click **Erase**:
   - **Name**: whatever the recipient wants
   - **Format**: `ExFAT` (universal — Mac + Windows + Linux) or `APFS` (if recipient is Mac-only)
   - **Scheme**: `GUID Partition Map`
   - **Security Options**: pick the highest option offered (usually "Fastest" — that's the right answer on SSD)
5. Click **Erase**. Takes ~30 seconds.

---

## Step 7 — Paranoid mode (optional, ~30 min)

If the drive is going to someone you don't fully trust, fill the new empty volume with random data. This forces fresh writes to cells the SSD controller hasn't yet TRIM'd, exercising wear-leveling against every physical block:

```bash
ls /Volumes/                              # confirm new volume name
dd if=/dev/urandom of=/Volumes/<name>/junk.bin bs=1m
# Runs ~15-30 min on 1 TB USB-C SSD
# Ends with: "dd: writing to '...junk.bin': No space left on device"
# That error is EXPECTED — it means the disk filled
rm /Volumes/<name>/junk.bin
```

Then optionally re-run Disk Utility erase one more time to leave the partition table fresh for the recipient.

---

## Step 8 — Verify the snapshot is gone

```bash
# The snapshot mount may still be active from step 3 — unmount it first
cd ~        # so your shell isn't sitting in the snapshot path
sudo diskutil unmount force /tmp/snap-mount

# Now confirm no traces
diskutil apfs listSnapshots disk5s2        # should fail (volume erased)
tmutil destinationinfo                     # should say no destinations
ls /Volumes/                               # only your new empty volume
```

If the unmount errors with "Resource busy", your shell is still `cd`'d into the snapshot path — `cd ~` and retry.

---

## Common pitfalls

### "Operation not permitted" reading the snapshot
The mount succeeded but Terminal can't see content → Full Disk Access. System Settings → Privacy & Security → Full Disk Access → add Terminal.app, then retry.

### `tar` runs forever with no output
`tar` is silent by default. Add `-v` to see file-by-file progress. If you really want to know it's alive, `du -h <output>.tar.gz` in another shell shows growth.

### Archive comes out 10× bigger than expected
You forgot an exclude. Most common culprits: `a_code_project/` (or your code dir), `.npm`, `.ollama`, `Library`, `node_modules`. Re-run with them added.

### `gunzip -t` fails after a long tar run
Previous attempt was interrupted (Ctrl+C, mount disconnect, or sudo-vs-non-sudo permission conflict on the output file). Delete the bad archive and retry. If the file is root-owned (from an earlier `sudo tar`), use `sudo rm` to remove it.

### `umount: Resource busy`
Your shell is `cd`'d into the mount, or Spotlight is indexing. `cd ~` then `sudo diskutil unmount force <path>`. If still busy: `sudo lsof <path>` to find the holder.

---

## What to add to next time's backup script

The `export-credentials.sh` in this repo's `scripts/` was updated based on this exercise. The key additions:

```bash
# Catch-all flat sweep of ~/ root with denylist (not allowlist)
tar -czf "$DEST/home-root-overflow.tar.gz" -C "$HOME" . \
  --exclude='./a_code_project' --exclude='./Library' \
  --exclude='./node_modules' --exclude='./venv' \
  --exclude='./.npm' --exclude='./.yarn' --exclude='./.cache' \
  --exclude='./.ollama' --exclude='./.gradle' --exclude='./.konan' \
  # ... (full list in the script)
```

This is the difference between a *curated* backup (what you remember to enumerate) and a *catch-all* backup (everything except the obvious skip list). The catch-all costs ~3-5 GB and ~5 minutes per backup — cheap insurance against the migration blind spot.
