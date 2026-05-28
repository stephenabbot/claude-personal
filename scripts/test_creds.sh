#!/usr/bin/env bash
# test_creds.sh — verify end-to-end connectivity: Keychain → MFA → STS → Bedrock
# Can be executed from any directory.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { printf "${GREEN}✓${NC}  %s\n" "$*"; }
fail() { printf "${RED}✗${NC}  %s\n" "$*" >&2; exit 1; }
warn() { printf "${YELLOW}⚠${NC}  %s\n" "$*"; }
step() { echo; printf "${BOLD}==> %s${NC}\n" "$*"; }

REGION="us-east-1"

# ── preflight ─────────────────────────────────────────────────────────────────

step "Checking prerequisites..."
echo ""

PREFLIGHT_FAILED=0
chk() {
  if command -v "$2" &>/dev/null; then
    printf "  ${GREEN}✓${NC}  %-20s %s\n" "$1" "$(command -v "$2")"
  else
    printf "  ${RED}✗${NC}  %-20s fix: %s\n" "$1" "$3" >&2
    PREFLIGHT_FAILED=1
  fi
}

chk "AWS CLI"   "aws"      "brew install awscli"
chk "jq"        "jq"       "brew install jq"
chk "security"  "security" "requires macOS"

echo ""
[[ "$PREFLIGHT_FAILED" -eq 1 ]] && fail "Missing prerequisites — install items above and retry."
ok "Prerequisites OK"

# ── resolve iam username ──────────────────────────────────────────────────────

step "Resolving IAM username..."

DEFAULT_USER=$(security find-generic-password -a claude-bedrock -s aws-bedrock-iam-user -w 2>/dev/null || echo "")

if [[ -n "$DEFAULT_USER" ]]; then
  read -rp "    IAM username [$DEFAULT_USER]: " INPUT_USER
  IAM_USER="${INPUT_USER:-$DEFAULT_USER}"
else
  read -rp "    IAM username: " IAM_USER
fi

[[ -z "$IAM_USER" ]] && fail "IAM username cannot be empty."
ok "Using IAM user: $IAM_USER"

# ── retrieve credentials from keychain ───────────────────────────────────────

step "Retrieving credentials from Keychain..."

ACCOUNT_ID=$(security find-generic-password -a claude-bedrock -s aws-bedrock-account-id -w 2>/dev/null) \
  || fail "Account ID not found in Keychain. Run: $PROJECT_DIR/scripts/deploy.sh"
AWS_ACCESS_KEY_ID=$(security find-generic-password -a claude-bedrock -s aws-bedrock-access-key -w 2>/dev/null) \
  || fail "Access key not found in Keychain. Run: $PROJECT_DIR/scripts/deploy.sh"
AWS_SECRET_ACCESS_KEY=$(security find-generic-password -a claude-bedrock -s aws-bedrock-secret-key -w 2>/dev/null) \
  || fail "Secret key not found in Keychain. Run: $PROJECT_DIR/scripts/deploy.sh"

MFA_ARN="arn:aws:iam::${ACCOUNT_ID}:mfa/${IAM_USER}"

[[ -z "$AWS_ACCESS_KEY_ID" ]]     && fail "Access key retrieved from Keychain was empty."
[[ -z "$AWS_SECRET_ACCESS_KEY" ]] && fail "Secret key retrieved from Keychain was empty."
ok "Credentials retrieved  (account: $ACCOUNT_ID)"

# ── prompt for mfa token ──────────────────────────────────────────────────────

echo
read -rsp "Enter TOTP MFA code for $IAM_USER: " MFA_TOKEN
echo

[[ -z "$MFA_TOKEN" ]]              && fail "No MFA code entered."
[[ ! "$MFA_TOKEN" =~ ^[0-9]{6}$ ]] && fail "MFA code must be exactly 6 digits (got: '$MFA_TOKEN')."

# ── request session token from sts ───────────────────────────────────────────

step "Requesting STS session token (6-hour expiry)..."

CREDS=$(AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
        AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
        aws sts get-session-token \
          --serial-number "$MFA_ARN" \
          --token-code "$MFA_TOKEN" \
          --duration-seconds 21600 \
          --region "$REGION" \
          --output json 2>&1) \
  || fail "STS get-session-token failed. Common causes:
     - Wrong or expired MFA code (wait for your authenticator app to show a fresh code)
     - Access key or secret is incorrect
     - MFA device ARN is wrong  (expected: $MFA_ARN)
     - IAM policy missing sts:GetSessionToken
     AWS response: $CREDS"

# ── parse credentials ─────────────────────────────────────────────────────────

export AWS_ACCESS_KEY_ID=$(    echo "$CREDS" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(    echo "$CREDS" | jq -r '.Credentials.SessionToken')
EXPIRATION=$(                  echo "$CREDS" | jq -r '.Credentials.Expiration')

[[ -z "$AWS_SESSION_TOKEN" || "$AWS_SESSION_TOKEN" == "null" ]] \
  && fail "Session token was empty after parsing STS response."

ok "Session token obtained — expires: $EXPIRATION"

# ── verify identity ───────────────────────────────────────────────────────────

step "Verifying identity via STS..."

IDENTITY=$(aws sts get-caller-identity --output json 2>&1) \
  || fail "get-caller-identity failed: $IDENTITY"

CALLER_ACCOUNT=$(echo "$IDENTITY" | jq -r '.Account')
USER_ARN=$(      echo "$IDENTITY" | jq -r '.Arn')
ok "Authenticated as: $USER_ARN  (account: $CALLER_ACCOUNT)"

# ── verify bedrock access ─────────────────────────────────────────────────────

step "Verifying Bedrock access..."

MODELS_JSON=$(aws bedrock list-foundation-models \
  --region "$REGION" \
  --output json \
  --query 'modelSummaries[?contains(modelId, `anthropic`)].modelId' 2>&1) \
  || fail "Bedrock list-foundation-models failed. Common causes:
     - Bedrock not reachable (check IAM policy includes bedrock:ListFoundationModels)
     - IAM policy missing bedrock:ListFoundationModels
     - Region $REGION may not support Bedrock — try us-west-2
     AWS response: $MODELS_JSON"

MODEL_COUNT=$(echo "$MODELS_JSON" | jq 'length')
ok "Bedrock reachable — $MODEL_COUNT Anthropic models listed in $REGION:"
echo "$MODELS_JSON" | jq -r '.[]' | while read -r m; do
  printf "     - %s\n" "$m"
done

# ── verify model access (invocation test) ─────────────────────────────────────
# Models are auto-enabled on first invocation, but first-time Anthropic users may
# need to submit use case details. A live invocation confirms end-to-end access.

step "Verifying model access (invocation test)..."

# Pick the first available Anthropic model from the list to test with.
# Prefer Haiku (cheapest); fall back to whatever is listed.
TEST_MODEL=$(echo "$MODELS_JSON" | jq -r '[.[] | select(contains("haiku"))] | first // .[0]')

if [[ -z "$TEST_MODEL" || "$TEST_MODEL" == "null" ]]; then
  warn "No Anthropic models listed — skipping invocation test."
else
  INVOKE_BODY_FILE=$(mktemp)
  INVOKE_OUT=$(mktemp)
  echo -n '{"anthropic_version":"bedrock-2023-05-31","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' > "$INVOKE_BODY_FILE"

  INVOKE_RESULT=$(aws bedrock-runtime invoke-model \
    --model-id "$TEST_MODEL" \
    --body "fileb://$INVOKE_BODY_FILE" \
    --content-type "application/json" \
    --accept "application/json" \
    --region "$REGION" \
    "$INVOKE_OUT" 2>&1)
  INVOKE_STATUS=$?
  rm -f "$INVOKE_OUT" "$INVOKE_BODY_FILE"

  if [[ "$INVOKE_STATUS" -eq 0 ]]; then
    ok "Model access confirmed — $TEST_MODEL responded"
  else
    if echo "$INVOKE_RESULT" | grep -qi "don't have access\|not have access\|model access\|AccessDeniedException"; then
      fail "Model not accessible: $TEST_MODEL
     Fix: Try invoking the model once in the Bedrock console playground.
          First-time Anthropic users may need to submit use case details.
          If issue persists, check that your IAM policy allows bedrock:InvokeModel."
    else
      fail "Invocation test failed for $TEST_MODEL:
     $INVOKE_RESULT"
    fi
  fi
fi

# ── done ──────────────────────────────────────────────────────────────────────

echo ""
printf "${GREEN}${BOLD}All checks passed.${NC}\n"
printf "Temp credentials exported in this shell session.\n"
printf "Expires: %s\n" "$EXPIRATION"
