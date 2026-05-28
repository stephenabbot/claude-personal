#!/usr/bin/env bash
# auth-bedrock.sh — obtain a 6-hour MFA-authenticated session for Bedrock
# Usage: source ./scripts/auth-bedrock.sh  (from project root)
#        source auth-bedrock.sh            (from scripts/ directory)
# Do NOT execute directly — exports won't persist in the calling shell.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { printf "${GREEN}✓${NC}  %s\n" "$*"; }
fail() { printf "${RED}✗${NC}  %s\n" "$*" >&2; return 1; }
step() { echo; printf "${BOLD}==> %s${NC}\n" "$*"; }

# ── read all values from keychain ─────────────────────────────────────────────

step "Retrieving credentials from Keychain..."

_kc() {
  security find-generic-password -a claude-bedrock -s "$1" -w 2>/dev/null \
    || { fail "Keychain entry '$1' not found. Have you run scripts/deploy.sh?"; return 1; }
}

IAM_USER=$(   _kc aws-bedrock-iam-user)   || return 1
ACCOUNT_ID=$( _kc aws-bedrock-account-id) || return 1
_ACCESS_KEY=$(_kc aws-bedrock-access-key) || return 1
_SECRET_KEY=$(_kc aws-bedrock-secret-key) || return 1

MFA_ARN="arn:aws:iam::${ACCOUNT_ID}:mfa/${IAM_USER}"
REGION="${AWS_REGION:-us-east-1}"

ok "Credentials retrieved  (user: $IAM_USER, account: $ACCOUNT_ID)"

# ── prompt for mfa token ──────────────────────────────────────────────────────

echo
read -rp "Enter TOTP MFA code for $IAM_USER: " MFA_TOKEN

[[ ! "$MFA_TOKEN" =~ ^[0-9]{6}$ ]] && { fail "MFA code must be exactly 6 digits."; return 1; }

# ── request session token from sts ───────────────────────────────────────────

step "Requesting STS session token (6-hour expiry)..."

CREDS=$(AWS_ACCESS_KEY_ID="$_ACCESS_KEY" \
        AWS_SECRET_ACCESS_KEY="$_SECRET_KEY" \
        aws sts get-session-token \
          --serial-number "$MFA_ARN" \
          --token-code "$MFA_TOKEN" \
          --duration-seconds 21600 \
          --region "$REGION" \
          --output json 2>&1) \
  || { fail "STS request failed — wrong MFA code, or credentials are incorrect.\n$CREDS"; return 1; }

# ── parse and export credentials ──────────────────────────────────────────────

export AWS_ACCESS_KEY_ID=$(    echo "$CREDS" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(    echo "$CREDS" | jq -r '.Credentials.SessionToken')
export AWS_DEFAULT_REGION="$REGION"
EXPIRATION=$(                  echo "$CREDS" | jq -r '.Credentials.Expiration')

[[ -z "$AWS_SESSION_TOKEN" || "$AWS_SESSION_TOKEN" == "null" ]] \
  && { fail "Session token was empty — STS response may be malformed."; return 1; }

ok "Session active until: $EXPIRATION"

unset _ACCESS_KEY _SECRET_KEY CREDS MFA_TOKEN
