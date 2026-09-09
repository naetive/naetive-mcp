#!/usr/bin/env bash
#
# Naetive bootstrap installer
# Usage:
#   curl -fsSL https://naetive.ai/install | bash
#
# Or, to inspect first (recommended):
#   curl -fsSL https://naetive.ai/install -o naetive-install.sh
#   less naetive-install.sh
#   bash naetive-install.sh
#
# What this script does:
#   1. Detects your environment (Claude Code presence, jq, curl)
#   2. Prompts for your Naetive auth token (paste from Connect page)
#   3. Writes ~/.claude/naetive.json with the token (user-level enable)
#   4. Registers the Naetive MCP server with Claude Code (`claude mcp add`, user scope)
#   5. Notes the Naetive plugin (private beta — coming soon)
#   6. Verifies the connection by hitting /api/v2/diagnostics/me
#   7. Generates an uninstaller at ~/.claude/naetive-uninstall.sh
#   8. Prints a summary
#
# Reverses cleanly: ~/.claude/naetive-uninstall.sh removes everything.
# Source: https://github.com/naetive/naetive-mcp/blob/main/install.sh

set -euo pipefail

# ── Branding ──────────────────────────────────────────────────────────
BANNER='
  ╔════════════════════════════╗
  ║       N A E T I V E        ║
  ║  bootstrap installer       ║
  ╚════════════════════════════╝
'

# ── Config ────────────────────────────────────────────────────────────
# Defaults are NAETIVE (the served /install is the raw repo file — no env
# substitution — so a frozen default silently pointed every install at the
# dead legacy backend). GATEWAY_URL is the gateway host directly (it serves
# both /mcp and /v1/telemetry/local-tools); the app domain naetive.ai does NOT
# proxy /v1/telemetry, and mcp.naetive.ai is not live yet, so use the raw
# gateway host until that custom domain exists (#177).
# Env overrides read NAETIVE_PLATFORM_URL / NAETIVE_GATEWAY_URL / NAETIVE_AUTH_TOKEN (no legacy fallback).
# so existing scripts/CI keep working (backward-compat identifier migration).
PLATFORM_URL="${NAETIVE_PLATFORM_URL:-https://naetive.ai}"
GATEWAY_URL="${NAETIVE_GATEWAY_URL:-https://naetive-gateway-production.up.railway.app}"
MCP_URL="${GATEWAY_URL}/mcp"
CLAUDE_DIR="$HOME/.claude"
# User-level config (no users yet, so no legacy fallback).
NAETIVE_CONFIG="$CLAUDE_DIR/naetive.json"

# ── Pretty output ─────────────────────────────────────────────────────
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }
err()  { echo "  ✗ $*" 1>&2; }
step() { echo ""; echo "── $* ──"; }
ask()  { echo -n "  $* "; }

echo "$BANNER"

# ── Step 1: Environment check ─────────────────────────────────────────
step "Step 1 — checking environment"

if [[ -z "${BASH_VERSION:-}" ]]; then
  err "Run with bash, not sh. Try: curl -fsSL ${PLATFORM_URL}/install | bash"
  exit 1
fi
ok "bash $(echo "$BASH_VERSION" | cut -d'(' -f1)"

if ! command -v curl >/dev/null 2>&1; then
  err "curl is required and not installed."
  exit 1
fi
ok "curl"

if ! command -v jq >/dev/null 2>&1; then
  warn "jq not found — recommended for JSON merging in MCP config"
  warn "Install: brew install jq | sudo apt install jq | sudo dnf install jq"
  HAS_JQ=0
else
  ok "jq $(jq --version)"
  HAS_JQ=1
fi

CLAUDE_FOUND=0
CLAUDE_INSTALLED_NOW=0
# NAETIVE_SKIP_CLAUDE=1 → "Naetive only" setup: install the console/tunnel/Node but
# NOT Claude Code, so users on Codex/ChatGPT (or without a Claude subscription)
# get the full Naetive local stack and connect their own agent from the Connect page.
SKIP_CLAUDE="${NAETIVE_SKIP_CLAUDE:-0}"
# NAETIVE_TUNNEL_ONLY=1 → lightweight "just the tunnel" install for a cloud agent
# (e.g. ChatGPT) that only needs local file access. Implies skip Claude + skip console.
TUNNEL_ONLY="${NAETIVE_TUNNEL_ONLY:-0}"
if [[ "$TUNNEL_ONLY" == "1" ]]; then SKIP_CLAUDE=1; fi
if command -v claude >/dev/null 2>&1; then
  ok "claude (Claude Code CLI)"
  CLAUDE_FOUND=1
elif [[ "$SKIP_CLAUDE" == "1" ]]; then
  ok "Naetive-only setup — skipping Claude Code (no Claude subscription needed)"
  warn "After this, connect your agent (Codex, ChatGPT, Claude, …) from the Connect page."
else
  warn "Claude Code isn't installed — installing it now…"
  # Anthropic's canonical native installer (macOS/Linux/WSL). Claude Code is a
  # native app — no Node/npm needed for Claude Code itself. Guard against the
  # sub-installer's non-zero exit killing us under `set -euo pipefail`.
  curl -fsSL https://claude.ai/install.sh | bash || true

  # The installer typically drops the binary in ~/.local/bin, which may not be
  # on PATH in this shell yet. Add it so the re-check (and Step 4) can find it.
  if [[ -d "$HOME/.local/bin" ]] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH="$HOME/.local/bin:$PATH"
  fi

  if command -v claude >/dev/null 2>&1; then
    ok "Installed Claude Code ($(claude --version 2>/dev/null || echo 'native app'))"
    CLAUDE_FOUND=1
    CLAUDE_INSTALLED_NOW=1
  else
    warn "Couldn't install Claude Code automatically (network/unsupported platform?)"
    warn "Install it manually, then re-run this installer:"
    echo "    curl -fsSL https://claude.ai/install.sh | bash"
    warn "MCP registration below will print a manual command you can run later."
  fi
fi

# If we just installed Claude Code (native → ~/.local/bin), persist that dir on
# PATH in the user's shell profile so `claude` works in future terminals. The
# native installer warns about this but doesn't do it. Idempotent.
if [[ "$CLAUDE_INSTALLED_NOW" == "1" ]] && [[ -d "$HOME/.local/bin" ]]; then
  case "${SHELL:-}" in
    *zsh)  PROFILE="$HOME/.zshrc" ;;
    *bash) if [[ -f "$HOME/.bash_profile" ]]; then PROFILE="$HOME/.bash_profile"; else PROFILE="$HOME/.bashrc"; fi ;;
    *)     PROFILE="$HOME/.profile" ;;
  esac
  if [[ -f "$PROFILE" ]] && grep -qF '.local/bin' "$PROFILE" 2>/dev/null; then
    ok "PATH already includes ~/.local/bin in $(basename "$PROFILE")"
  else
    printf '\n# Added by Naetive installer — Claude Code lives in ~/.local/bin\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$PROFILE"
    ok "Added ~/.local/bin to PATH in $(basename "$PROFILE") — open a new terminal (or: source $PROFILE)"
  fi
fi

# Node 20+ powers the in-browser console + tunnel (Steps 5b/5c). If it's missing
# or too old, install it FOR the user via nvm (user-level, NO sudo) so "set it up
# for me" truly needs nothing pre-installed. Heavily guarded: a failed Node
# install can NEVER abort the script — it degrades to a clear nodejs.org message.
NODE_OK=0
NODE_INSTALLED_NOW=0
node_ok_check() {
  command -v node >/dev/null 2>&1 || return 1
  local maj; maj="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [[ "$maj" =~ ^[0-9]+$ ]] && (( maj >= 20 ))
}
if node_ok_check; then
  ok "node $(node --version)"
  NODE_OK=1
else
  warn "Node 20+ not found — installing it for you (user-level, no sudo)…"
  # Relax strict mode around nvm: its script + sourcing aren't `set -euo pipefail`
  # clean, and we never want it to kill the installer.
  set +eu
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash >/tmp/naetive-nvm.log 2>&1 || true
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    . "$NVM_DIR/nvm.sh" || true
    nvm install 20 >/tmp/naetive-node-install.log 2>&1 || true
    nvm use 20 >/dev/null 2>&1 || true
  fi
  set -eu
  if node_ok_check; then
    ok "Installed Node $(node --version) (via nvm)"
    NODE_OK=1
    NODE_INSTALLED_NOW=1
  else
    warn "Couldn't auto-install Node (see /tmp/naetive-node-install.log)."
    warn "Install it from https://nodejs.org (LTS) and re-run — the in-browser terminal needs it."
  fi
fi

# ── Step 2: Get the user's token ──────────────────────────────────────
step "Step 2 — Naetive auth token"

# Prefer env var (CI / repeat installs); else prompt.
TOKEN="${NAETIVE_AUTH_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  echo "  Open the Connect page in your browser to grab your token:"
  echo "    ${PLATFORM_URL}/?tab=connect"
  echo "  (Account card → 👁 Show → 📋 Copy)"
  echo ""
  ask "Paste your token (cb_…):"
  # Read from the controlling terminal, NOT stdin. When invoked via
  # `curl ... | bash`, stdin is the curl pipe — `read` would otherwise
  # silently capture an empty value.
  if [[ -r /dev/tty ]]; then
    read -r TOKEN < /dev/tty
  else
    read -r TOKEN
  fi
fi

if [[ -z "$TOKEN" || ! "$TOKEN" =~ ^cb_ ]]; then
  err "Token must start with 'cb_'. Got: ${TOKEN:0:8}…"
  err "Find your token on the Connect page → Account → Copy."
  exit 1
fi
ok "Token captured (cb_${TOKEN:3:6}…${TOKEN: -4})"

# ── Step 3: Write user-level naetive.json ─────────────────────────────
step "Step 3 — writing user-level config"

mkdir -p "$CLAUDE_DIR"
if [[ -f "$NAETIVE_CONFIG" ]]; then
  cp "$NAETIVE_CONFIG" "${NAETIVE_CONFIG}.bak.$(date +%s)"
  ok "Existing config backed up to ${NAETIVE_CONFIG}.bak.<ts>"
fi

cat > "$NAETIVE_CONFIG" <<EOF
{
  "auth_token": "$TOKEN",
  "gateway_url": "$GATEWAY_URL"
}
EOF
chmod 600 "$NAETIVE_CONFIG"
ok "Wrote $NAETIVE_CONFIG (mode 0600)"
ok "User-level telemetry enabled — all Claude Code windows will report"
ok "Per-folder opt-out: 'touch .claude/naetive-disabled' in any project"

# ── Step 3b: activity telemetry hook (decoupled from the plugin) ──────
# The PostToolUse hook reports local file activity so agent presence stays
# "connected" while an agent works locally (no MCP calls). This is
# INFRASTRUCTURE and ships HERE — NOT in the gated, private-beta plugin.
# Single source of truth: the platform serves the canonical script at
# /naetive-telemetry.sh; we download + register it. Independent of the console.
step "Step 3b — activity telemetry hook"
HOOKS_DIR="$HOME/.naetive/hooks"
TELEMETRY_HOOK="$HOOKS_DIR/naetive-telemetry.sh"
mkdir -p "$HOOKS_DIR"
if curl -fsSL "${PLATFORM_URL}/naetive-telemetry.sh" -o "$TELEMETRY_HOOK"; then
  chmod +x "$TELEMETRY_HOOK"
  ok "Telemetry hook installed at $TELEMETRY_HOOK"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$CLAUDE_DIR/settings.json" "$TELEMETRY_HOOK" <<'PY'
import json, os, sys
settings, hook = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(settings)) if os.path.exists(settings) else {}
except Exception:
    d = {}
arr = d.setdefault('hooks', {}).setdefault('PostToolUse', [])
if not any(hook in hk.get('command', '') for x in arr for hk in x.get('hooks', [])):
    arr.append({'hooks': [{'type': 'command', 'command': hook}]})
    json.dump(d, open(settings, 'w'), indent=2)
    print('registered')
else:
    print('already present')
PY
    ok "PostToolUse telemetry hook registered — local file activity now reports"
  else
    warn "python3 not found — hook downloaded but not registered; add a PostToolUse hook pointing at $TELEMETRY_HOOK"
  fi
else
  warn "Couldn't download the telemetry hook from ${PLATFORM_URL}/naetive-telemetry.sh — presence will rely on MCP calls only"
fi

# ── Step 4: MCP server config ─────────────────────────────────────────
step "Step 4 — Claude Code MCP server config"

# Register via the supported `claude mcp add` command. This writes to the
# location Claude Code actually reads (user scope → ~/.claude.json) — NOT
# ~/.config/claude-code/mcp_config.json, which Claude Code does not read.
# Idempotent: remove any prior 'naetive' entry first.
MCP_ADD_CMD=$(printf 'claude mcp add --scope user --transport http naetive "%s" --header "Authorization: Bearer %s"' "$MCP_URL" "$TOKEN")
MCP_OK=0
# Log to a 0600 file (not a world-readable /tmp path): `claude mcp add` may echo
# the Authorization header on error, and the bearer token must not linger in a
# file other users can read. Created with umask 077, removed on success.
MCP_ADD_LOG="${TMPDIR:-/tmp}/naetive-mcp-add.$$.log"
( umask 077; : > "$MCP_ADD_LOG" ) 2>/dev/null || MCP_ADD_LOG="/dev/null"
if [[ "$CLAUDE_FOUND" == "1" ]]; then
  claude mcp remove --scope user naetive >/dev/null 2>&1 || true
  if claude mcp add --scope user --transport http naetive "$MCP_URL" \
       --header "Authorization: Bearer $TOKEN" >"$MCP_ADD_LOG" 2>&1; then
    ok "Registered 'naetive' MCP server (user scope)"
    MCP_OK=1
    rm -f "$MCP_ADD_LOG" 2>/dev/null || true
  else
    warn "Couldn't auto-register the MCP server (details in ${MCP_ADD_LOG}, readable only by you)"
    warn "Run this once inside a terminal:"
    echo "    claude mcp add --scope user --transport http naetive \"$MCP_URL\" --header \"Authorization: Bearer <your-token>\""
  fi
elif [[ "$SKIP_CLAUDE" == "1" ]]; then
  ok "Naetive-only setup — skipping Claude Code MCP registration"
  echo "    Connect your agent (Codex / ChatGPT / Claude / …) from the Connect page — it sets"
  echo "    up the right config for that agent. Naetive's console + tunnel are ready below."
else
  warn "Claude Code CLI not found — install Claude Code, then register Naetive with:"
  echo "    claude mcp add --scope user --transport http naetive \"$MCP_URL\" --header \"Authorization: Bearer <your-token>\""
fi

# ── Step 5: Naetive plugin (coming soon) ───────────────────────────────
step "Step 5 — Naetive plugin (coming soon)"

warn "The Naetive Claude Code plugin (slash commands + cognition injection) is in private beta."
ok "Nothing to install here yet — a one-line command will appear on Connect when it's public."

# ── Step 5b: Local console (powers in-browser terminals) ──────────────
step "Step 5b — local console (in-browser terminals)"

NAETIVE_HOME="$HOME/.naetive"
mkdir -p "$NAETIVE_HOME"
CONSOLE_DIR="$NAETIVE_HOME/console"
CONSOLE_LAUNCHER="$NAETIVE_HOME/start-console.sh"
CONSOLE_TARBALL_URL="${PLATFORM_URL}/console.tar.gz"

console_running() { curl -fsS --max-time 2 "http://localhost:4000/api/config" >/dev/null 2>&1; }

if [[ "$TUNNEL_ONLY" == "1" ]]; then
  ok "Tunnel-only setup — skipping the local console (in-browser terminals)"
elif command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  echo "  Installing the local console to $CONSOLE_DIR …"
  mkdir -p "$NAETIVE_HOME"
  TMP_TAR="$(mktemp)"
  if curl -fsSL "$CONSOLE_TARBALL_URL" -o "$TMP_TAR"; then
    rm -rf "$CONSOLE_DIR"; mkdir -p "$CONSOLE_DIR"
    tar xzf "$TMP_TAR" -C "$CONSOLE_DIR" --strip-components=1
    rm -f "$TMP_TAR"
    echo "  Building console dependencies (compiles node-pty, ~1 min)…"
    if (cd "$CONSOLE_DIR" && npm install --omit=dev --no-audit --no-fund >/tmp/naetive-console-npm.log 2>&1); then
      ok "Local console installed"
      cat > "$CONSOLE_LAUNCHER" <<EOF
#!/usr/bin/env bash
# Start the Naetive local console (in-browser terminals). Listens on :4000.
cd "$CONSOLE_DIR" && exec node server.js
EOF
      chmod +x "$CONSOLE_LAUNCHER"
      if console_running; then
        ok "Console already running on :4000"
      else
        nohup "$CONSOLE_LAUNCHER" >"$NAETIVE_HOME/console.log" 2>&1 &
        sleep 2
        if console_running; then
          ok "Console started on :4000"
        else
          warn "Console installed but didn't confirm on :4000 yet — start it with: $CONSOLE_LAUNCHER"
        fi
      fi

      # Register the Claude Code grounding hooks so agents arrive pre-loaded with
      # project context: SessionStart injects the project brief; UserPromptSubmit
      # injects topic-relevant recorded work. Idempotent. (python3 required — the
      # hook scripts use it too.) See platform Foundation doc "Agent Grounding".
      if command -v python3 >/dev/null 2>&1; then
        python3 - "$CLAUDE_DIR/settings.json" "$CONSOLE_DIR/hooks" <<'PY'
import json, os, sys
settings, hooks_dir = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(settings)) if os.path.exists(settings) else {}
except Exception:
    d = {}
h = d.setdefault('hooks', {})
wanted = [
    ('SessionStart',    os.path.join(hooks_dir, 'bind-conversation.sh')),
    ('UserPromptSubmit', os.path.join(hooks_dir, 'scoped-context.sh')),
]
changed = False
for event, cmd in wanted:
    arr = h.setdefault(event, [])
    if not any(cmd in hk.get('command', '') for x in arr for hk in x.get('hooks', [])):
        arr.append({'hooks': [{'type': 'command', 'command': cmd}]})
        changed = True
if changed:
    json.dump(d, open(settings, 'w'), indent=2)
print('registered' if changed else 'already present')
PY
        ok "Grounding hooks registered — agents start with project context"
      else
        warn "python3 not found — grounding hooks skipped (chats still work, just not auto-grounded)"
      fi
    else
      warn "Console dependency build failed (see /tmp/naetive-console-npm.log)"
      warn "Retry later with: cd $CONSOLE_DIR && npm install"
    fi
  else
    warn "Couldn't download the console from $CONSOLE_TARBALL_URL — skipping"
  fi
else
  warn "Node.js + npm not found — skipping the local console."
  warn "The in-browser Terminal needs it. Install Node 20+ and re-run this installer."
fi

# ── Step 5c: Local tunnel (for ChatGPT / Codex file access) ───────────
step "Step 5c — local tunnel (ChatGPT / Codex file access)"

TUNNEL_DIR="$NAETIVE_HOME/tunnel"
TUNNEL_LAUNCHER="$NAETIVE_HOME/start-tunnel.sh"
TUNNEL_TARBALL_URL="${PLATFORM_URL}/tunnel.tar.gz"

if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  echo "  Installing the tunnel to $TUNNEL_DIR …"
  mkdir -p "$NAETIVE_HOME"
  TMP_TT="$(mktemp)"
  if curl -fsSL "$TUNNEL_TARBALL_URL" -o "$TMP_TT"; then
    rm -rf "$TUNNEL_DIR"; mkdir -p "$TUNNEL_DIR"
    tar xzf "$TMP_TT" -C "$TUNNEL_DIR" --strip-components=1
    rm -f "$TMP_TT"
    echo "  Installing tunnel dependencies…"
    if (cd "$TUNNEL_DIR" && npm install --omit=dev --no-audit --no-fund >/tmp/naetive-tunnel-npm.log 2>&1); then
      ok "Tunnel installed"
      # Launcher bakes in api + token; user runs it IN the project folder they
      # want the cloud AI to access (the tunnel root = current directory).
      cat > "$TUNNEL_LAUNCHER" <<EOF
#!/usr/bin/env bash
# Start the Naetive tunnel — lets ChatGPT/Codex reach files in THIS folder.
# Run it from the project directory you want the AI to access.
exec node "$TUNNEL_DIR/bin/naetive-tunnel.js" --api="$PLATFORM_URL" --token="$TOKEN" "\$@"
EOF
      chmod +x "$TUNNEL_LAUNCHER"
      ok "Tunnel ready — start it in a project with: $TUNNEL_LAUNCHER"
    else
      warn "Tunnel dependency install failed (see /tmp/naetive-tunnel-npm.log)"
    fi
  else
    warn "Couldn't download the tunnel from $TUNNEL_TARBALL_URL — skipping"
  fi
else
  warn "Node.js + npm not found — skipping the tunnel."
fi

# ── Step 6: Verification ──────────────────────────────────────────────
step "Step 6 — verifying"

DIAG_URL="${PLATFORM_URL}/api/v2/diagnostics/me"
HTTP_CODE=$(curl -s -o /tmp/naetive-diag.json -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  "$DIAG_URL" || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
  ok "Auth + diagnostics endpoint reachable"
  if [[ "$HAS_JQ" == "1" ]]; then
    OVERALL=$(jq -r '.overall_status // "unknown"' /tmp/naetive-diag.json 2>/dev/null || echo "unknown")
    echo "    Current telemetry status: $OVERALL"
    echo "    (will turn 'healthy' once you use Claude Code with the new config)"
  fi
else
  warn "Diagnostics endpoint returned HTTP $HTTP_CODE"
  warn "Token may be wrong. Generate a new one on the Connect page if needed."
fi
rm -f /tmp/naetive-diag.json

# ── Step 7: Uninstaller ───────────────────────────────────────────────
step "Step 7 — generating uninstaller"

UNINSTALL="$CLAUDE_DIR/naetive-uninstall.sh"
cat > "$UNINSTALL" <<'EOF'
#!/usr/bin/env bash
# Naetive uninstaller — removes user-level config and MCP server entry.
set -euo pipefail
echo "Removing Naetive user-level telemetry config…"
rm -f "$HOME/.claude/naetive.json"
echo "Stopping + removing local console + tunnel…"
# Kill the running console (:4000) / tunnel first — rm -rf alone leaves the
# background processes running until reboot.
if command -v lsof >/dev/null 2>&1; then
  lsof -ti:4000 2>/dev/null | xargs kill 2>/dev/null || true
fi
pkill -f "\.naetive/console" 2>/dev/null || true
pkill -f "\.naetive/tunnel" 2>/dev/null || true
rm -rf "$HOME/.naetive/console" "$HOME/.naetive/start-console.sh"
rm -rf "$HOME/.naetive/tunnel" "$HOME/.naetive/start-tunnel.sh"
echo "Removing the activity telemetry hook…"
rm -f "$HOME/.naetive/hooks/naetive-telemetry.sh" "$HOME/.claude/.naetive-telemetry-error"
echo "Removing Naetive from Claude Code MCP config…"
if command -v claude >/dev/null 2>&1; then
  claude mcp remove --scope user naetive >/dev/null 2>&1 || true
fi
echo "Removing Naetive grounding hooks from Claude settings…"
SETTINGS="$HOME/.claude/settings.json"
if [[ -f "$SETTINGS" ]] && command -v python3 >/dev/null 2>&1; then
  python3 - "$SETTINGS" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
h = d.get('hooks', {})
MARKERS = ('.naetive/console/hooks', 'naetive-telemetry')
for event in ('SessionStart', 'UserPromptSubmit', 'PostToolUse'):
    arr = h.get(event)
    if not isinstance(arr, list):
        continue
    kept = [x for x in arr if not any(any(m in hk.get('command', '') for m in MARKERS) for hk in x.get('hooks', []))]
    if kept:
        h[event] = kept
    else:
        h.pop(event, None)
json.dump(d, open(sys.argv[1], 'w'), indent=2)
PY
fi
echo "✓ Naetive uninstalled. (Plugin must be removed inside Claude Code: /plugin uninstall memeri)"
EOF
chmod +x "$UNINSTALL"
ok "Uninstaller at $UNINSTALL"

# ── Done ──────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ✓ Naetive configured."
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  • Token:    cb_${TOKEN:3:6}…${TOKEN: -4}"
echo "  • Hook:     enabled at user level (~/.claude/naetive.json)"
if [[ "$CLAUDE_INSTALLED_NOW" == "1" ]]; then
echo "  • Claude:   installed Claude Code now (run 'claude' once to sign in)"
elif [[ "$CLAUDE_FOUND" == "1" ]]; then
echo "  • Claude:   already installed (Claude Code CLI present)"
else
echo "  • Claude:   NOT installed — run: curl -fsSL https://claude.ai/install.sh | bash"
fi
if [[ "$MCP_OK" == "1" ]]; then
echo "  • MCP:      registered with Claude Code (user scope)"
else
echo "  • MCP:      ACTION NEEDED — run: claude mcp add --scope user --transport http naetive \"$MCP_URL\" --header \"Authorization: Bearer <token>\""
fi
echo "  • Plugin:   coming soon (private beta — nothing to install yet)"
echo "  • Console:  installed at ~/.naetive/console (start: ~/.naetive/start-console.sh)"
echo "  • Tunnel:   installed (ChatGPT/Codex file access) — start in a project: ~/.naetive/start-tunnel.sh"
echo ""
echo "  Next:"
if [[ "$CLAUDE_INSTALLED_NOW" == "1" ]]; then
echo "    0. Run 'claude' once to sign in (opens a browser for auth)."
fi
echo "    1. Open Claude Code."
echo "    2. Run /mcp — confirm 'naetive' is connected."
echo "    3. Open Naetive → Connect — the pre-flight checks should turn green."
echo "    4. Open Naetive → Terminal — launch an agent on your project."
echo "    5. (ChatGPT/Codex only) run ~/.naetive/start-tunnel.sh in your project folder."
echo ""
echo "  Trouble? See ${PLATFORM_URL}/?tab=wiki — Telemetry → Troubleshooting"
echo ""
