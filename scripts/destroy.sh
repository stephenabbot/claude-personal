#!/usr/bin/env bash
# destroy.sh — fully remove all artifacts created by deploy.sh
# Removes: Keychain entries, Claude Code npm package, launcher, PATH entry in ~/.zshrc
# Does NOT remove the project directory or scripts — those are source files, not artifacts.
# Can be executed from any directory.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

pass()  { printf "  ${GREEN}✓${NC}  %-36s ${GREEN}%s${NC}\n"  "$1" "$2"; }
miss()  { printf "  ${YELLOW}·${NC}  %-36s ${YELLOW}%s${NC}\n" "$1" "$2"; }
step()  { echo;  printf "${BOLD}==> %s${NC}\n" "$*"; }

LAUNCHER="$HOME/bin/claude-personal"

echo ""
printf "${BOLD}claude-personal — destroy${NC}\n"
echo "════════════════════════════════════════════════"
printf "${YELLOW}Removes all artifacts created by deploy.sh.${NC}\n"
printf "${YELLOW}Scripts and documentation are not affected.${NC}\n"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — AUDIT what artifacts exist
# ══════════════════════════════════════════════════════════════════════════════

step "Auditing deploy artifacts..."
echo ""

ACTION_COUNT=0

# Keychain entries
KC_USER=$(security find-generic-password -a claude-bedrock -s aws-bedrock-iam-user   -w 2>/dev/null || echo "")
KC_ACCT=$(security find-generic-password -a claude-bedrock -s aws-bedrock-account-id -w 2>/dev/null || echo "")
KC_KEY=$( security find-generic-password -a claude-bedrock -s aws-bedrock-access-key -w 2>/dev/null || echo "")
KC_SEC=$( security find-generic-password -a claude-bedrock -s aws-bedrock-secret-key -w 2>/dev/null || echo "")

HAS_KEYCHAIN=0
if [[ -n "$KC_USER" || -n "$KC_ACCT" || -n "$KC_KEY" || -n "$KC_SEC" ]]; then
  HAS_KEYCHAIN=1
  ACTION_COUNT=$((ACTION_COUNT+1))
  [[ -n "$KC_USER" ]] && pass "Keychain: iam-user"   "$KC_USER"         || miss "Keychain: iam-user"   "not found"
  [[ -n "$KC_ACCT" ]] && pass "Keychain: account-id" "$KC_ACCT"         || miss "Keychain: account-id" "not found"
  [[ -n "$KC_KEY"  ]] && pass "Keychain: access-key" "${KC_KEY:0:8}..."  || miss "Keychain: access-key" "not found"
  [[ -n "$KC_SEC"  ]] && pass "Keychain: secret-key" "stored"            || miss "Keychain: secret-key" "not found"
else
  miss "Keychain entries" "none found"
fi

# Claude Code npm package
HAS_CLAUDE=0
if [[ -x "$PROJECT_DIR/node_modules/.bin/claude" ]]; then
  CLAUDE_VER=$("$PROJECT_DIR/node_modules/.bin/claude" --version 2>/dev/null || echo "unknown")
  pass "Claude Code" "v$CLAUDE_VER at $PROJECT_DIR/node_modules"
  HAS_CLAUDE=1; ACTION_COUNT=$((ACTION_COUNT+1))
else
  miss "Claude Code" "not installed"
fi

# npm package artifacts (package.json, package-lock.json, node_modules)
HAS_NPM_ARTIFACTS=0
if [[ -f "$PROJECT_DIR/package.json" || -f "$PROJECT_DIR/package-lock.json" || -d "$PROJECT_DIR/node_modules" ]]; then
  [[ -f "$PROJECT_DIR/package.json" ]]      && pass "package.json"      "$PROJECT_DIR/package.json"
  [[ -f "$PROJECT_DIR/package-lock.json" ]] && pass "package-lock.json" "$PROJECT_DIR/package-lock.json"
  [[ -d "$PROJECT_DIR/node_modules" ]]      && pass "node_modules/"     "$PROJECT_DIR/node_modules"
  HAS_NPM_ARTIFACTS=1; ACTION_COUNT=$((ACTION_COUNT+1))
else
  miss "npm artifacts" "none found"
fi

# Launcher
HAS_LAUNCHER=0
if [[ -f "$LAUNCHER" ]]; then
  pass "Launcher" "$LAUNCHER"
  HAS_LAUNCHER=1; ACTION_COUNT=$((ACTION_COUNT+1))
else
  miss "Launcher" "not found"
fi

# PATH entry in .zshrc
HAS_PATH_ENTRY=0
if grep -q 'PATH.*HOME/bin\|PATH.*~/bin' "$HOME/.zshrc" 2>/dev/null; then
  pass "PATH entry" "~/bin in ~/.zshrc"
  HAS_PATH_ENTRY=1; ACTION_COUNT=$((ACTION_COUNT+1))
else
  miss "PATH entry" "not found in ~/.zshrc"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — PLAN
# ══════════════════════════════════════════════════════════════════════════════

echo ""
printf "${BOLD}════════════════════════════════════════════════${NC}\n"
printf "${BOLD}Plan — the following artifacts will be removed:${NC}\n"
echo ""

if [[ "$ACTION_COUNT" -eq 0 ]]; then
  printf "${GREEN}Nothing to remove — no deploy artifacts found.${NC}\n"
  exit 0
fi

[[ "$HAS_KEYCHAIN"      -eq 1 ]] && printf "  ${RED}·${NC}  Keychain entries (iam-user, account-id, access-key, secret-key)\n"
[[ "$HAS_CLAUDE"        -eq 1 ]] && printf "  ${RED}·${NC}  Claude Code npm package\n"
[[ "$HAS_NPM_ARTIFACTS" -eq 1 ]] && printf "  ${RED}·${NC}  npm artifacts (package.json, package-lock.json, node_modules/)\n"
[[ "$HAS_LAUNCHER"      -eq 1 ]] && printf "  ${RED}·${NC}  Launcher: %s\n" "$LAUNCHER"
[[ "$HAS_PATH_ENTRY"    -eq 1 ]] && printf "  ${RED}·${NC}  PATH entry for ~/bin in ~/.zshrc\n"

echo ""
printf "${YELLOW}Scripts and documentation in %s are not affected.${NC}\n" "$PROJECT_DIR"
echo ""
printf "${YELLOW}${BOLD}This cannot be undone.${NC}\n"
echo ""
read -rp "Type 'destroy' to confirm: " CONFIRM
[[ "$CONFIRM" == "destroy" ]] || { echo "Aborted."; exit 0; }

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — EXECUTE
# ══════════════════════════════════════════════════════════════════════════════

step "Removing artifacts..."
echo ""

if [[ "$HAS_KEYCHAIN" -eq 1 ]]; then
  _del() {
    security delete-generic-password -a claude-bedrock -s "$1" 2>/dev/null \
      && printf "  ${GREEN}✓${NC}  Removed Keychain: %s\n" "$1" \
      || printf "  ${YELLOW}·${NC}  Already gone: %s\n" "$1"
  }
  _del aws-bedrock-iam-user
  _del aws-bedrock-account-id
  _del aws-bedrock-access-key
  _del aws-bedrock-secret-key
fi

if [[ "$HAS_CLAUDE" -eq 1 ]]; then
  cd "$PROJECT_DIR" && npm uninstall @anthropic-ai/claude-code --save 2>/dev/null \
    && printf "  ${GREEN}✓${NC}  Claude Code npm package removed\n" \
    || printf "  ${YELLOW}⚠${NC}  npm uninstall encountered an issue\n"
fi

if [[ "$HAS_NPM_ARTIFACTS" -eq 1 ]]; then
  rm -rf "$PROJECT_DIR/node_modules" \
    && printf "  ${GREEN}✓${NC}  node_modules/ removed\n"
  rm -f  "$PROJECT_DIR/package.json" \
    && printf "  ${GREEN}✓${NC}  package.json removed\n"
  rm -f  "$PROJECT_DIR/package-lock.json" \
    && printf "  ${GREEN}✓${NC}  package-lock.json removed\n"
fi

if [[ "$HAS_LAUNCHER" -eq 1 ]]; then
  rm -f "$LAUNCHER" \
    && printf "  ${GREEN}✓${NC}  Launcher removed: %s\n" "$LAUNCHER"
fi

if [[ "$HAS_PATH_ENTRY" -eq 1 ]]; then
  sed -i '' '/export PATH="\$HOME\/bin:\$PATH"/d' "$HOME/.zshrc" 2>/dev/null \
    && printf "  ${GREEN}✓${NC}  PATH entry removed from ~/.zshrc\n" \
    || printf "  ${YELLOW}⚠${NC}  Could not remove PATH entry — remove manually from ~/.zshrc\n"
fi

echo ""
echo "════════════════════════════════════════════════"
printf "${GREEN}${BOLD}Destroy complete.${NC}\n"
echo ""
printf "Scripts and docs remain in: %s\n" "$PROJECT_DIR"
printf "Run deploy.sh to set up again.\n"
echo ""
echo "Note: IAM user and AWS policy were not removed — delete manually in AWS Console if needed."
