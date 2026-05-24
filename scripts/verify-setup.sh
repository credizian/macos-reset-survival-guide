#!/bin/bash
# Post-restore sanity check. Run after restore.sh + sign-ins. Reports
# pass/warn/fail per check.

pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }

echo "================================================================"
echo "Setup verification — $(date)"
echo "================================================================"

# --- Identity ---
echo ""
echo "Identity"
name=$(git config --global user.name)
email=$(git config --global user.email)
[ -n "$name" ] && pass "git user.name = $name" || fail "git user.name not set"
[ -n "$email" ] && pass "git user.email = $email" || fail "git user.email not set"
br=$(git config --global init.defaultBranch)
[ -n "$br" ] && pass "git init.defaultBranch = $br" || warn "git init.defaultBranch not set"

# --- SSH ---
echo ""
echo "SSH"
[ -f ~/.ssh/id_ed25519 ] && pass "id_ed25519 present" || warn "id_ed25519 missing (you may use a different key)"
if [ -f ~/.ssh/id_ed25519 ]; then
  perm=$(stat -f "%Lp" ~/.ssh/id_ed25519)
  [ "$perm" = "600" ] && pass "id_ed25519 perms = 600" || fail "id_ed25519 perms = $perm (expected 600)"
fi
if ssh -T -o BatchMode=yes -o ConnectTimeout=5 git@github.com 2>&1 | grep -q "successfully authenticated"; then
  pass "SSH to github.com authenticated"
else
  warn "SSH to github.com failed (run: ssh -T git@github.com to debug, or HTTPS may be fine)"
fi

# --- AWS ---
echo ""
echo "AWS"
[ -f ~/.aws/credentials ] && pass "~/.aws/credentials present" || warn "~/.aws/credentials missing"
[ -f ~/.aws/config ] && pass "~/.aws/config present" || warn "~/.aws/config missing"
if command -v aws >/dev/null 2>&1; then
  pass "aws CLI installed"
  caller=$(aws sts get-caller-identity 2>&1)
  if echo "$caller" | grep -q "Arn"; then
    pass "AWS credentials valid"
  else
    warn "aws sts failed — may need 'aws sso login' or fresh credentials"
  fi
else
  fail "aws CLI not installed (brew install awscli)"
fi

# --- gh (GitHub CLI) ---
echo ""
echo "GitHub CLI"
if command -v gh >/dev/null 2>&1; then
  pass "gh installed"
  if gh auth status 2>&1 | grep -q "Logged in"; then
    pass "gh authenticated as $(gh api user --jq .login 2>/dev/null)"
  else
    fail "gh not authenticated — run: gh auth login"
  fi
else
  fail "gh not installed"
fi

# --- Node / npm ---
echo ""
echo "Node"
if command -v node >/dev/null 2>&1; then
  pass "node $(node --version) at $(which node)"
else
  fail "node not on PATH"
fi
command -v npm >/dev/null 2>&1 && pass "npm $(npm --version)" || fail "npm missing"

# --- Docker ---
echo ""
echo "Docker"
if command -v docker >/dev/null 2>&1; then
  pass "docker $(docker --version | cut -d' ' -f3 | tr -d ',')"
  if docker info >/dev/null 2>&1; then
    pass "Docker Desktop is running"
  else
    warn "docker CLI installed but daemon not running (open Docker Desktop)"
  fi
else
  warn "docker not installed (was in Brewfile if you had it)"
fi

# --- Homebrew ---
echo ""
echo "Homebrew"
if command -v brew >/dev/null 2>&1; then
  pass "brew $(brew --version | head -1 | cut -d' ' -f2)"
  pass "$(brew list --formula | wc -l | tr -d ' ') formulae, $(brew list --cask | wc -l | tr -d ' ') casks"
else
  fail "brew not installed"
fi

# --- Apps ---
# NOTE: MySQL Workbench's bundle is "MySQLWorkbench" (no space).
# 1Password 8 ships as just "1Password".
echo ""
echo "Apps installed"
for app in "Arc" "Dropbox" "1Password" "Visual Studio Code" "Cursor" "Sublime Text" "MySQLWorkbench" "DBeaver" "Docker" "Rectangle" "Raycast" "GitHub Desktop" "Firefox" "Claude"; do
  if [ -d "/Applications/$app.app" ]; then
    pass "$app"
  else
    warn "$app missing (manual install, MAS, or different name)"
  fi
done

# --- Claude Code CLI ---
echo ""
echo "Claude Code CLI"
[ -f ~/.claude/CLAUDE.md ] && pass "CLAUDE.md" || warn "CLAUDE.md missing"
[ -f ~/.claude/settings.json ] && pass "settings.json" || warn "settings.json missing"
[ -d ~/.claude/rules ] && pass "rules/" || warn "rules/ missing"

# --- Claude Desktop ---
echo ""
echo "Claude Desktop"
CLAUDE_APP_DIR="$HOME/Library/Application Support/Claude"
[ -d "$CLAUDE_APP_DIR" ] && pass "data dir exists" || warn "no data dir — has Claude.app been launched?"
[ -f "$CLAUDE_APP_DIR/claude_desktop_config.json" ] && pass "claude_desktop_config.json present" || warn "claude_desktop_config.json missing"
trusted=$(python3 -c "import json; d=json.load(open('$CLAUDE_APP_DIR/claude_desktop_config.json',encoding='utf-8')); print(len(d.get('preferences',{}).get('localAgentModeTrustedFolders',[])))" 2>/dev/null || echo "0")
[ "$trusted" -gt 0 ] 2>/dev/null && pass "$trusted trusted folders" || warn "no trusted folders (Claude will re-prompt per folder)"
sessions=$(find "$CLAUDE_APP_DIR/local-agent-mode-sessions" -maxdepth 3 -name "local_*.json" 2>/dev/null | wc -l | tr -d ' ')
[ "$sessions" -gt 0 ] && pass "$sessions Cowork session files" || warn "no Cowork sessions (empty if fresh install)"

# --- Security ---
echo ""
echo "Security"
if grep -qE "^export.*(API_KEY|TOKEN)=" ~/.zshrc 2>/dev/null; then
  warn "⚠ API keys/tokens still in .zshrc plaintext — rotate them and move to a secret manager"
else
  pass "No plaintext API_KEY/TOKEN exports in .zshrc"
fi
fdesetup status 2>/dev/null | grep -q "FileVault is On" && pass "FileVault is ON" || warn "FileVault is OFF (enable in System Settings → Privacy & Security)"

echo ""
echo "================================================================"
echo "Done. Resolve anything marked ✗ or ! above."
