#!/usr/bin/env bash
# deploy.sh — one-time (or repeat) setup for claude-personal
# Safe to re-run — audits current state and only performs what is needed.
# Can be executed from any directory.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── colors & output helpers ───────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass()  { printf "  ${GREEN}✓${NC}  %-36s ${GREEN}%s${NC}\n"  "$1" "$2"; }
miss()  { printf "  ${RED}✗${NC}  %-36s ${RED}%s${NC}\n"    "$1" "$2"; }
warn()  { printf "  ${YELLOW}⚠${NC}  %-36s ${YELLOW}%s${NC}\n" "$1" "$2"; }
info()  { printf "  ${CYAN}·${NC}  %-36s %s\n"               "$1" "$2"; }
step()  { echo;  printf "${BOLD}==> %s${NC}\n" "$*"; }
fail()  { printf "\n${RED}${BOLD}[FAIL]${NC} %s\n" "$*" >&2; exit 1; }
# prompt: visible input (non-sensitive values)
# prompt_secret: silent input — not echoed to terminal, protects against
#   session recorders, terminal scrollback, and screen capture
prompt()       { read -rp  "    $1: " "$2"; }
prompt_secret(){ read -rsp "    $1: " "$2"; echo ""; }

LAUNCHER="$HOME/bin/claude-personal"
AUTH_SCRIPT="$PROJECT_DIR/scripts/auth-bedrock.sh"
CLAUDE_BIN="$PROJECT_DIR/node_modules/.bin/claude"

echo ""
printf "${BOLD}claude-personal — setup${NC}\n"
echo "════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — AUDIT
# ══════════════════════════════════════════════════════════════════════════════

step "Auditing prerequisites..."
echo ""

PREREQ_FAILED=0

check_cmd() {
  local label="$1" cmd="$2" fix="$3"
  if command -v "$cmd" &>/dev/null; then
    pass "$label" "$(command -v "$cmd")"
  else
    miss "$label" "fix: $fix"
    PREREQ_FAILED=1
  fi
}

check_cmd "macOS Keychain (security)" "security" "requires macOS"
check_cmd "Homebrew"                  "brew"     "https://brew.sh"
check_cmd "AWS CLI"                   "aws"      "brew install awscli"
check_cmd "jq"                        "jq"       "brew install jq"
check_cmd "npm"                       "npm"      "brew install fnm && fnm install 22"

BASH_MAJOR=$(bash --version 2>/dev/null | head -1 | grep -oE 'version [0-9]+' | grep -oE '[0-9]+' || echo "0")
BASH_FULL=$(bash  --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
if [[ "$BASH_MAJOR" -ge 5 ]]; then
  pass "Bash >= 5" "v$BASH_FULL"
else
  miss "Bash >= 5" "fix: brew install bash  (current: v$BASH_FULL)"
  PREREQ_FAILED=1
fi

if command -v aws &>/dev/null; then
  AWS_VER=$(aws --version 2>&1 | grep -oE 'aws-cli/[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  AWS_MAJOR=$(echo "$AWS_VER" | grep -oE '[0-9]+' | head -1)
  if [[ "${AWS_MAJOR:-0}" -ge 2 ]]; then
    pass "AWS CLI v2" "$AWS_VER"
  else
    miss "AWS CLI v2" "fix: brew install awscli  (current: $AWS_VER)"
    PREREQ_FAILED=1
  fi
fi

if command -v node &>/dev/null; then
  NODE_VER=$(node --version | sed 's/v//')
  NODE_MAJOR=$(echo "$NODE_VER" | cut -d. -f1)
  if [[ "$NODE_MAJOR" -ge 18 ]]; then
    pass "Node.js >= 18" "v$NODE_VER"
  else
    miss "Node.js >= 18" "fix: brew install fnm && fnm install 22  (current: v$NODE_VER)"
    PREREQ_FAILED=1
  fi
else
  miss "Node.js >= 18" "fix: brew install fnm && fnm install 22"
  PREREQ_FAILED=1
fi

if command -v jq &>/dev/null; then
  pass "jq" "$(jq --version 2>/dev/null)"
fi

warn "TOTP authenticator app" "verify IAM user MFA is enrolled before continuing"

echo ""
if [[ "$PREREQ_FAILED" -eq 1 ]]; then
  printf "${RED}${BOLD}Prerequisites missing — install items marked ✗ and re-run.${NC}\n"
  exit 1
fi
printf "${GREEN}${BOLD}All prerequisites satisfied.${NC}\n"

# ── audit keychain ────────────────────────────────────────────────────────────

step "Auditing Keychain entries..."
echo ""

KC_USER=$(security find-generic-password -a claude-bedrock -s aws-bedrock-iam-user   -w 2>/dev/null || echo "")
KC_ACCT=$(security find-generic-password -a claude-bedrock -s aws-bedrock-account-id -w 2>/dev/null || echo "")
KC_KEY=$( security find-generic-password -a claude-bedrock -s aws-bedrock-access-key -w 2>/dev/null || echo "")
KC_SEC=$( security find-generic-password -a claude-bedrock -s aws-bedrock-secret-key -w 2>/dev/null || echo "")

NEED_KEYCHAIN=0
[[ -n "$KC_USER" ]] && pass "Keychain: iam-user"   "$KC_USER"          || { miss "Keychain: iam-user"   "will prompt"; NEED_KEYCHAIN=1; }
[[ -n "$KC_ACCT" ]] && pass "Keychain: account-id" "$KC_ACCT"          || { miss "Keychain: account-id" "will prompt"; NEED_KEYCHAIN=1; }
[[ -n "$KC_KEY"  ]] && pass "Keychain: access-key" "${KC_KEY:0:8}..."   || { miss "Keychain: access-key" "will prompt"; NEED_KEYCHAIN=1; }
[[ -n "$KC_SEC"  ]] && pass "Keychain: secret-key" "stored"             || { miss "Keychain: secret-key" "will prompt"; NEED_KEYCHAIN=1; }

# ── audit claude code ─────────────────────────────────────────────────────────

step "Auditing Claude Code installation..."
echo ""

NEED_NPM=0
if [[ -f "$PROJECT_DIR/package.json" ]]; then
  pass "npm project" "$PROJECT_DIR/package.json"
else
  miss "npm project" "will run npm init"
  NEED_NPM=1
fi

if [[ -x "$CLAUDE_BIN" ]]; then
  INSTALLED_VER=$("$CLAUDE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
  LATEST_VER=$(npm view @anthropic-ai/claude-code version 2>/dev/null || echo "unknown")
  if [[ "$INSTALLED_VER" == "$LATEST_VER" ]]; then
    pass "Claude Code" "v$INSTALLED_VER (latest)"
  else
    info "Claude Code" "installed: v$INSTALLED_VER → latest: v$LATEST_VER (will update)"
    NEED_NPM=1
  fi
else
  miss "Claude Code binary" "will install @anthropic-ai/claude-code"
  NEED_NPM=1
fi

# ── audit launcher & PATH ─────────────────────────────────────────────────────

step "Auditing Bedrock region and model access..."
echo ""

BEDROCK_REGION="${AWS_REGION:-us-east-1}"
KNOWN_BEDROCK_REGIONS=("us-east-1" "us-west-2" "eu-west-1" "eu-central-1" "ap-northeast-1" "ap-southeast-1" "ap-southeast-2")
REGION_VALID=0
for r in "${KNOWN_BEDROCK_REGIONS[@]}"; do
  [[ "$r" == "$BEDROCK_REGION" ]] && REGION_VALID=1 && break
done

if [[ "$REGION_VALID" -eq 1 ]]; then
  pass "Bedrock region" "$BEDROCK_REGION"
else
  warn "Bedrock region" "$BEDROCK_REGION — not a known Bedrock region. Supported: ${KNOWN_BEDROCK_REGIONS[*]}"
fi

# Probe Bedrock model access using the current session's credentials.
# list-foundation-models succeeds for everyone regardless of model access;
# only a live invocation confirms that at least one model has been enabled.
_PROBE_FILE=$(mktemp)
_PROBE_OUT=$(mktemp)
echo -n '{"anthropic_version":"bedrock-2023-05-31","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' > "$_PROBE_FILE"
BEDROCK_MODEL_OK=0
BEDROCK_TEST_MODEL=""
for _TRY_MODEL in \
    "us.anthropic.claude-haiku-4-5-20251001-v1:0" \
    "anthropic.claude-haiku-4-5-20251001-v1:0" \
    "us.anthropic.claude-sonnet-4-6" \
    "anthropic.claude-sonnet-4-6"; do
  aws bedrock-runtime invoke-model \
    --model-id "$_TRY_MODEL" \
    --body "fileb://$_PROBE_FILE" \
    --content-type "application/json" \
    --accept "application/json" \
    --region "$BEDROCK_REGION" \
    "$_PROBE_OUT" >/dev/null 2>&1 \
    && { BEDROCK_MODEL_OK=1; BEDROCK_TEST_MODEL="$_TRY_MODEL"; break; }
done
rm -f "$_PROBE_FILE" "$_PROBE_OUT"

if [[ "$BEDROCK_MODEL_OK" -eq 1 ]]; then
  pass "Bedrock model access" "$BEDROCK_TEST_MODEL"
else
  miss "Bedrock model access" "no Claude model responded in $BEDROCK_REGION"
  printf "       ${CYAN}Fix: AWS Console → Amazon Bedrock → Model access → Modify model access${NC}\n"
  printf "       ${CYAN}     Enable Anthropic Claude models, then re-run deploy.sh${NC}\n"
  printf "       ${CYAN}     Once enabled, run: source scripts/test_creds.sh  to verify${NC}\n"
fi

step "Auditing launcher and PATH..."
echo ""

NEED_LAUNCHER=0
NEED_PATH=0

# Detect the shell rc file to update based on the user's default shell.
# We update the rc file so PATH persists in new terminals, and also export
# immediately in the current process so no sourcing is required after deploy.
case "$SHELL" in
  */zsh)
    SHELL_RC="$HOME/.zshrc"
    SHELL_NAME="zsh"
    ;;
  */bash)
    # bash on Mac uses .bash_profile for login shells (default in Terminal/iTerm2)
    if [[ -f "$HOME/.bash_profile" ]]; then
      SHELL_RC="$HOME/.bash_profile"
    else
      SHELL_RC="$HOME/.bashrc"
    fi
    SHELL_NAME="bash"
    ;;
  */fish)
    SHELL_RC="$HOME/.config/fish/config.fish"
    SHELL_NAME="fish"
    ;;
  *)
    SHELL_RC="$HOME/.profile"
    SHELL_NAME="unknown"
    ;;
esac

if [[ -x "$LAUNCHER" ]]; then
  pass "Launcher" "$LAUNCHER"
else
  miss "Launcher" "will install to $LAUNCHER"
  NEED_LAUNCHER=1
fi

if [[ "$SHELL_NAME" == "fish" ]]; then
  # fish uses different PATH syntax — check and warn rather than auto-write
  if grep -q 'set.*PATH.*bin' "$SHELL_RC" 2>/dev/null; then
    pass "~/bin on PATH" "$SHELL_RC"
  else
    miss "~/bin on PATH (fish)" "add manually: set -gx PATH \$HOME/bin \$PATH  →  $SHELL_RC"
    NEED_PATH=1
  fi
else
  if grep -q 'PATH.*HOME/bin\|PATH.*~/bin' "$SHELL_RC" 2>/dev/null; then
    pass "~/bin on PATH" "$SHELL_RC ($SHELL_NAME)"
  else
    miss "~/bin on PATH" "will add to $SHELL_RC"
    NEED_PATH=1
  fi
fi

if [[ -x "$AUTH_SCRIPT" ]]; then
  pass "auth-bedrock.sh" "$AUTH_SCRIPT"
else
  miss "auth-bedrock.sh" "not found at $AUTH_SCRIPT"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — PLAN
# ══════════════════════════════════════════════════════════════════════════════

echo ""
printf "${BOLD}════════════════════════════════════════════════${NC}\n"
printf "${BOLD}Plan — the following actions will be taken:${NC}\n"
echo ""

ACTION_COUNT=0

if [[ "$NEED_KEYCHAIN"  -eq 1 ]]; then printf "  ${CYAN}·${NC}  Prompt for missing credentials and store in macOS Keychain\n"; ACTION_COUNT=$((ACTION_COUNT+1)); fi
if [[ "$NEED_NPM"       -eq 1 ]]; then printf "  ${CYAN}·${NC}  Install / update Claude Code via npm\n";                       ACTION_COUNT=$((ACTION_COUNT+1)); fi
if [[ "$NEED_LAUNCHER"  -eq 1 ]]; then printf "  ${CYAN}·${NC}  Install launcher to %s\n" "$LAUNCHER";                        ACTION_COUNT=$((ACTION_COUNT+1)); fi
if [[ "$NEED_PATH"      -eq 1 ]]; then printf "  ${CYAN}·${NC}  Add ~/bin to PATH in ~/.zshrc\n";                             ACTION_COUNT=$((ACTION_COUNT+1)); fi

if [[ "$ACTION_COUNT" -eq 0 ]]; then
  echo ""
  printf "${GREEN}${BOLD}Nothing to do — everything is already set up.${NC}\n"
  echo ""
  echo "To launch Claude: claude-personal"
  exit 0
fi

echo ""
read -rp "Proceed? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — EXECUTE
# ══════════════════════════════════════════════════════════════════════════════

if [[ "$NEED_KEYCHAIN" -eq 1 ]]; then
  step "Collecting credentials..."
  echo "  You will need:"
  echo "    - IAM username          (e.g. a_ai)"
  echo "    - AWS account ID        (12-digit number, top-right of AWS Console)"
  echo "    - Access Key ID         (IAM → user → Security credentials)"
  echo "    - Secret Access Key     (only shown once at creation)"
  echo ""

  [[ -z "$KC_USER" ]] && prompt        "IAM username"      KC_USER
  [[ -z "$KC_ACCT" ]] && prompt        "AWS account ID"    KC_ACCT
  [[ -z "$KC_KEY"  ]] && prompt_secret "Access Key ID"     KC_KEY
  [[ -z "$KC_SEC"  ]] && prompt_secret "Secret Access Key" KC_SEC

  [[ -z "$KC_USER" ]] && fail "IAM username cannot be empty."
  [[ -z "$KC_ACCT" ]] && fail "Account ID cannot be empty."
  [[ -z "$KC_KEY"  ]] && fail "Access Key ID cannot be empty."
  [[ -z "$KC_SEC"  ]] && fail "Secret Access Key cannot be empty."
  [[ ! "$KC_ACCT" =~ ^[0-9]{12}$ ]]          && fail "Account ID must be exactly 12 digits."
  [[ ! "$KC_KEY"  =~ ^AKIA[A-Z0-9]{16}$ ]]   && fail "Access Key ID format looks wrong (expected: AKIA...)."

  step "Storing credentials in Keychain..."

  _store() {
    security add-generic-password    -a claude-bedrock -s "$1" -w "$2" 2>/dev/null \
      || security add-generic-password -U -a claude-bedrock -s "$1" -w "$2"
  }

  _store aws-bedrock-iam-user   "$KC_USER"
  _store aws-bedrock-account-id "$KC_ACCT"
  _store aws-bedrock-access-key "$KC_KEY"
  _store aws-bedrock-secret-key "$KC_SEC"

  CHECK_USER=$(security find-generic-password -a claude-bedrock -s aws-bedrock-iam-user   -w 2>/dev/null)
  CHECK_ACCT=$(security find-generic-password -a claude-bedrock -s aws-bedrock-account-id -w 2>/dev/null)
  CHECK_KEY=$( security find-generic-password -a claude-bedrock -s aws-bedrock-access-key -w 2>/dev/null)
  CHECK_SEC=$( security find-generic-password -a claude-bedrock -s aws-bedrock-secret-key -w 2>/dev/null)

  [[ "$CHECK_USER" == "$KC_USER" ]] || fail "Keychain round-trip failed for iam-user."
  [[ "$CHECK_ACCT" == "$KC_ACCT" ]] || fail "Keychain round-trip failed for account-id."
  [[ "$CHECK_KEY"  == "$KC_KEY"  ]] || fail "Keychain round-trip failed for access-key."
  [[ "$CHECK_SEC"  == "$KC_SEC"  ]] || fail "Keychain round-trip failed for secret-key."

  printf "${GREEN}✓${NC}  All 4 Keychain entries stored and verified\n"
fi

if [[ "$NEED_NPM" -eq 1 ]]; then
  step "Installing Claude Code..."
  mkdir -p "$PROJECT_DIR"
  if [[ ! -f "$PROJECT_DIR/package.json" ]]; then
    cd "$PROJECT_DIR" && npm init -y >/dev/null
  fi
  cd "$PROJECT_DIR" && npm install @anthropic-ai/claude-code@latest --save 2>&1 \
    | grep -E 'added|updated|up to date|claude-code' || true
  [[ -x "$CLAUDE_BIN" ]] || fail "Claude binary not found after install."
  NEW_VER=$("$CLAUDE_BIN" --version 2>/dev/null || echo "unknown")
  printf "${GREEN}✓${NC}  Claude Code ready — v%s\n" "$NEW_VER"
fi

if [[ "$NEED_LAUNCHER" -eq 1 ]]; then
  step "Installing launcher..."
  mkdir -p "$HOME/bin"

  cat > "$LAUNCHER" << 'LAUNCHER_SCRIPT'
#!/usr/bin/env bash
# ~/bin/claude-personal — Claude Code launcher via AWS Bedrock
set -uo pipefail

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

PROJECT_DIR="$HOME/projects/claude-personal"
CLAUDE_BIN="$PROJECT_DIR/node_modules/.bin/claude"
AUTH_SCRIPT="$PROJECT_DIR/scripts/auth-bedrock.sh"

# ── node bootstrap ────────────────────────────────────────────────────────────
# Try to locate node across the most common Mac version manager setups before
# failing. Handles fnm, nvm, and direct Homebrew installs transparently.
if ! command -v node &>/dev/null; then
  if command -v fnm &>/dev/null; then
    eval "$(fnm env 2>/dev/null)" && command -v node &>/dev/null
  fi
fi
if ! command -v node &>/dev/null; then
  NVM_INIT="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
  [[ -s "$NVM_INIT" ]] && source "$NVM_INIT" 2>/dev/null
fi
if ! command -v node &>/dev/null; then
  for NODE_PATH in /opt/homebrew/bin /usr/local/bin; do
    [[ -x "$NODE_PATH/node" ]] && export PATH="$NODE_PATH:$PATH" && break
  done
fi
if ! command -v node &>/dev/null; then
  echo "ERROR: node not found. Install via: brew install fnm && fnm install 22"
  echo "       Then add fnm init to your shell rc file and reopen your terminal."
  exit 1
fi

if [[ ! -x "$CLAUDE_BIN" ]]; then
  echo "ERROR: Claude binary not found. Run: $PROJECT_DIR/scripts/deploy.sh"
  exit 1
fi

if [[ ! -f "$AUTH_SCRIPT" ]]; then
  echo "ERROR: $AUTH_SCRIPT not found. See README.md."
  exit 1
fi

# ── auto-update ───────────────────────────────────────────────────────────────
INSTALLED_VER="$("$CLAUDE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0")"
LATEST_VER="$(npm view @anthropic-ai/claude-code version 2>/dev/null || echo "")"
if [[ -n "$LATEST_VER" && "$INSTALLED_VER" != "$LATEST_VER" ]]; then
  printf "${YELLOW}Updating Claude Code: v%s → v%s ...${NC}\n" "$INSTALLED_VER" "$LATEST_VER"
  cd "$PROJECT_DIR" && npm install @anthropic-ai/claude-code@latest --save >/dev/null 2>&1
  printf "${GREEN}✓${NC}  Claude Code updated to v%s\n" "$LATEST_VER"
fi

# ── aws authentication ────────────────────────────────────────────────────────
if [[ -z "${AWS_SESSION_TOKEN:-}" ]] || ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "No active AWS session — starting MFA authentication..."
  source "$AUTH_SCRIPT" || exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
IAM_USER="$(security find-generic-password -a claude-bedrock -s aws-bedrock-iam-user -w 2>/dev/null || echo "unknown")"
printf "${GREEN}✓${NC}  AWS account: %s (user: %s)\n" "$ACCOUNT_ID" "$IAM_USER"

# ── bedrock configuration ─────────────────────────────────────────────────────
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION="${AWS_REGION:-us-east-1}"
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-32000}"
export MAX_THINKING_TOKENS="${MAX_THINKING_TOKENS:-10000}"

# ── model selection ───────────────────────────────────────────────────────────
# Discovers the best Claude model your account has access to. On first launch
# of a session, queries list-foundation-models to get real model IDs for this
# region, then probes in capability order (opus > sonnet > haiku) with an
# 8-second timeout per model. Result is cached in /tmp for the duration of the
# 6-hour session — subsequent launches are instant.
# Set ANTHROPIC_MODEL in env to skip all probing.
if [[ -z "${ANTHROPIC_MODEL:-}" ]]; then
  SESSION_CACHE_KEY="${AWS_SESSION_TOKEN:0:16}"
  MODEL_CACHE="/tmp/.claude-personal-model-${SESSION_CACHE_KEY}"

  if [[ -f "$MODEL_CACHE" ]]; then
    SELECTED_MODEL=$(cut -d'|' -f1 < "$MODEL_CACHE")
    SELECTED_SMALL=$(cut -d'|' -f2 < "$MODEL_CACHE")
  else
    FMODELS_JSON=$(aws bedrock list-foundation-models \
      --region "$AWS_REGION" \
      --output json 2>/dev/null) || FMODELS_JSON='{"modelSummaries":[]}'

    RANKED_IDS=$(echo "$FMODELS_JSON" | jq -r '
      .modelSummaries[]
      | select(.modelId | test("^anthropic\\.claude"))
      | select(.inferenceTypesSupported // [] | (contains(["ON_DEMAND"]) or contains(["INFERENCE_PROFILE"])))
      | [
          (if (.modelId | test("opus"))     then 30
           elif (.modelId | test("sonnet")) then 20
           elif (.modelId | test("haiku"))  then 10
           else 0 end),
          .modelId
        ] | @tsv
    ' 2>/dev/null | sort -k1,1rn -k2,2r | cut -f2)

    PROBE_BODY_FILE=$(mktemp)
    PROBE_OUT=$(mktemp)
    echo -n '{"anthropic_version":"bedrock-2023-05-31","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' > "$PROBE_BODY_FILE"
    SELECTED_MODEL=""
    SELECTED_SMALL=""

    probe_model() {
      local MODEL_ID="$1"
      aws bedrock-runtime invoke-model \
        --model-id "$MODEL_ID" \
        --body "fileb://$PROBE_BODY_FILE" \
        --content-type "application/json" \
        --accept "application/json" \
        --region "$AWS_REGION" \
        "$PROBE_OUT" >/dev/null 2>&1 &
      local AWS_PID=$!
      local ELAPSED=0
      while [[ $ELAPSED -lt 8 ]]; do
        sleep 1; ELAPSED=$((ELAPSED + 1))
        if ! kill -0 "$AWS_PID" 2>/dev/null; then
          wait "$AWS_PID" 2>/dev/null; return $?
        fi
      done
      kill "$AWS_PID" 2>/dev/null; wait "$AWS_PID" 2>/dev/null; return 1
    }

    while IFS= read -r BASE_ID; do
      [[ -n "$BASE_ID" ]] || continue
      # Once the main model is found, only probe haiku/sonnet for the small model.
      # Skipping additional opus probes avoids burning limited opus throughput quota.
      if [[ -n "$SELECTED_MODEL" ]] && ! echo "$BASE_ID" | grep -qiE "haiku|sonnet"; then
        continue
      fi
      for MODEL_ID in "us.${BASE_ID}" "$BASE_ID"; do
        probe_model "$MODEL_ID" || continue
        [[ -z "$SELECTED_MODEL" ]] && SELECTED_MODEL="$MODEL_ID"
        if [[ -z "$SELECTED_SMALL" ]] && echo "$MODEL_ID" | grep -qiE "haiku|sonnet"; then
          SELECTED_SMALL="$MODEL_ID"
        fi
        break
      done
      [[ -n "$SELECTED_MODEL" && -n "$SELECTED_SMALL" ]] && break
    done <<< "$RANKED_IDS"
    rm -f "$PROBE_OUT" "$PROBE_BODY_FILE"

    if [[ -z "$SELECTED_MODEL" ]]; then
      printf "${RED}✗${NC}  No Claude models with access found in %s.\n" "$AWS_REGION"
      printf "   Fix: AWS Console → Amazon Bedrock → Model access → Modify model access\n"
      printf "        Enable at least one Anthropic Claude model, then re-run.\n"
      exit 1
    fi
    [[ -z "$SELECTED_SMALL" ]] && SELECTED_SMALL="$SELECTED_MODEL"

    echo "${SELECTED_MODEL}|${SELECTED_SMALL}" > "$MODEL_CACHE"
  fi

  if echo "$SELECTED_MODEL" | grep -qi "opus"; then
    printf "${GREEN}✓${NC}  Model: %s\n" "$SELECTED_MODEL"
  else
    printf "${YELLOW}⚠${NC}  Model: %s (Opus not available — enable in Bedrock console for full capability)\n" "$SELECTED_MODEL"
  fi

  export ANTHROPIC_MODEL="$SELECTED_MODEL"
  export ANTHROPIC_SMALL_FAST_MODEL="${ANTHROPIC_SMALL_FAST_MODEL:-$SELECTED_SMALL}"
else
  export ANTHROPIC_SMALL_FAST_MODEL="${ANTHROPIC_SMALL_FAST_MODEL:-us.anthropic.claude-haiku-4-5-20251001-v1:0}"
fi

printf '\033]0;Claude [%s]\007' "$ACCOUNT_ID"

exec "$CLAUDE_BIN" \
  --append-system-prompt "AWS account: $ACCOUNT_ID (user: $IAM_USER)." \
  "$@"
LAUNCHER_SCRIPT

  chmod +x "$LAUNCHER"
  printf "${GREEN}✓${NC}  Launcher installed to %s\n" "$LAUNCHER"
fi

if [[ "$NEED_PATH" -eq 1 ]]; then
  step "Updating PATH..."
  if [[ "$SHELL_NAME" == "fish" ]]; then
    printf "${YELLOW}⚠${NC}  Fish shell detected — add ~/bin to PATH manually:\n"
    printf "      echo 'set -gx PATH \$HOME/bin \$PATH' >> %s\n" "$SHELL_RC"
  else
    echo 'export PATH="$HOME/bin:$PATH"' >> "$SHELL_RC"
    printf "${GREEN}✓${NC}  Added ~/bin to PATH in %s\n" "$SHELL_RC"
    # Also export immediately so claude-personal is available right now
    # without requiring the user to source their rc file or open a new terminal.
    export PATH="$HOME/bin:$PATH"
    printf "${GREEN}✓${NC}  PATH updated in current shell — no restart needed\n"
  fi
fi

echo ""
echo "════════════════════════════════════════════════"
printf "${GREEN}${BOLD}Setup complete.${NC}\n"
echo ""
echo "Next steps:"
if [[ "$SHELL_NAME" == "fish" ]]; then
  echo "  1. Add ~/bin to PATH in $SHELL_RC (see above)"
  echo "  2. Restart your terminal"
  echo "  3. claude-personal"
else
  echo "  1. claude-personal"
fi
echo ""
echo "On first run you will be prompted for your TOTP MFA code."
echo "The session remains active for 6 hours."
