#!/usr/bin/env bash
# list-roles.sh — show deployed operational role stacks and their status
# Usage: scripts/list-roles.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROLES_DIR="$PROJECT_DIR/roles"

# ── colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

fail() { printf "${RED}${BOLD}[FAIL]${NC} %s\n" "$*" >&2; exit 1; }

# ── prerequisites ─────────────────────────────────────────────────────────────
if ! command -v aws &>/dev/null; then
  fail "AWS CLI not found."
fi

if [[ -z "${AWS_SESSION_TOKEN:-}" ]] || ! aws sts get-caller-identity &>/dev/null; then
  fail "No active AWS session. Run claude-personal to authenticate first."
fi

# ── list defined roles ────────────────────────────────────────────────────────
echo ""
printf "${BOLD}Operational Roles${NC}\n"
echo "════════════════════════════════════════════════════════════════════"
printf "  %-12s %-18s %-12s %s\n" "ROLE" "STATUS" "CREATED" "ARN"
echo "────────────────────────────────────────────────────────────────────"

for dir in "$ROLES_DIR"/*/; do
  ROLE_NAME=$(basename "$dir")
  [[ "$ROLE_NAME" == "_example" ]] && continue
  [[ -f "$dir/policy.json" ]] || continue

  STACK_NAME="claude-personal-role-${ROLE_NAME}"

  STACK_INFO=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query 'Stacks[0].[StackStatus,CreationTime,Outputs[?OutputKey==`RoleArn`].OutputValue|[0]]' \
    --output text 2>/dev/null || echo "NOT_DEPLOYED	-	-")

  STATUS=$(echo "$STACK_INFO" | cut -f1)
  CREATED=$(echo "$STACK_INFO" | cut -f2 | cut -c1-10)
  ARN=$(echo "$STACK_INFO" | cut -f3)

  [[ "$CREATED" == "None" || -z "$CREATED" ]] && CREATED="-"
  [[ "$ARN" == "None" || -z "$ARN" ]] && ARN="-"

  case "$STATUS" in
    *COMPLETE)       printf "  %-12s ${GREEN}%-18s${NC} %-12s %s\n" "$ROLE_NAME" "$STATUS" "$CREATED" "$ARN" ;;
    *FAILED|*ROLLBACK*) printf "  %-12s ${RED}%-18s${NC} %-12s %s\n" "$ROLE_NAME" "$STATUS" "$CREATED" "$ARN" ;;
    NOT_DEPLOYED)    printf "  %-12s ${YELLOW}%-18s${NC} %-12s %s\n" "$ROLE_NAME" "$STATUS" "-" "-" ;;
    *)               printf "  %-12s ${YELLOW}%-18s${NC} %-12s %s\n" "$ROLE_NAME" "$STATUS" "$CREATED" "$ARN" ;;
  esac
done

echo ""
