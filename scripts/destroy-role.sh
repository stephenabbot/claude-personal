#!/usr/bin/env bash
# destroy-role.sh — delete an operational role CloudFormation stack
# Usage: scripts/destroy-role.sh <role-name>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROLES_DIR="$PROJECT_DIR/roles"

# ── colors & output helpers ───────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

pass()  { printf "  ${GREEN}✓${NC}  %s\n" "$*"; }
fail()  { printf "\n${RED}${BOLD}[FAIL]${NC} %s\n" "$*" >&2; exit 1; }
info()  { printf "  ${YELLOW}·${NC}  %s\n" "$*"; }
step()  { echo;  printf "${BOLD}==> %s${NC}\n" "$*"; }

# ── prerequisites ─────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <role-name>"
  exit 1
fi

ROLE_NAME="$1"
STACK_NAME="claude-personal-role-${ROLE_NAME}"

if ! command -v aws &>/dev/null; then
  fail "AWS CLI not found."
fi

if [[ -z "${AWS_SESSION_TOKEN:-}" ]] || ! aws sts get-caller-identity &>/dev/null; then
  fail "No active AWS session. Run claude-personal to authenticate first."
fi

# ── verify stack exists ───────────────────────────────────────────────────────
STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [[ "$STACK_STATUS" == "DOES_NOT_EXIST" ]]; then
  fail "Stack '$STACK_NAME' does not exist. Nothing to destroy."
fi

step "Destroying role: $ROLE_NAME"
info "Stack: $STACK_NAME (status: $STACK_STATUS)"

echo ""
read -rp "  Are you sure you want to delete this role? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── delete stack ──────────────────────────────────────────────────────────────
aws cloudformation delete-stack --stack-name "$STACK_NAME" 2>&1 \
  || fail "delete-stack failed"

info "Waiting for deletion to complete..."

if aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" 2>/dev/null; then
  pass "Role '$ROLE_NAME' destroyed (stack $STACK_NAME deleted)"
else
  fail "Stack deletion failed. Check CloudFormation console."
fi

echo ""
