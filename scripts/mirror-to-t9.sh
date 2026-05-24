#!/bin/bash
# Mirror your code directory to an external SSD, excluding regenerable cruft.
# Run BEFORE the macOS reset.
#
# What it excludes (all of these can be regenerated locally):
#   - node_modules, .venv, venv, env, target, .turbo, .next, dist, build, out
#   - __pycache__, .pytest_cache, .gradle, .terraform, DerivedData, .cache
#   - *.log files
# What it keeps:
#   - Your source code, .git history, configs, .env files (those need to come with you)
#
# Customize SRC and DST below for your setup.

set -e

SRC="$HOME/a_code_project"        # ← change to your code dir
DST="/Volumes/T9 Files/a_code_project"  # ← change to your external drive

if [ ! -d "$SRC" ]; then
  echo "ERROR: SRC '$SRC' doesn't exist." >&2
  exit 1
fi
if [ ! -d "$(dirname "$DST")" ]; then
  echo "ERROR: DST parent '$(dirname "$DST")' not mounted." >&2
  exit 1
fi

echo "Mirroring $SRC → $DST (excluding regenerable cruft, keeping .git)..."
echo ""

# IMPORTANT: macOS system rsync doesn't support --info=progress2.
# Use brew-installed rsync if you want progress, or drop the flag.
rsync -a --delete \
  --exclude 'node_modules/' \
  --exclude '.next/' --exclude 'dist/' --exclude 'build/' --exclude 'out/' \
  --exclude 'target/' --exclude '__pycache__/' --exclude '.pytest_cache/' \
  --exclude '.venv/' --exclude 'venv/' --exclude 'env/' \
  --exclude '.turbo/' --exclude '.cache/' --exclude 'DerivedData/' \
  --exclude '.gradle/' --exclude '.terraform/' --exclude '*.log' \
  "$SRC/" "$DST/"

echo ""
echo "DONE. Size on destination:"
du -sh "$DST"
echo ""
echo "Run again before reset to capture latest changes."
