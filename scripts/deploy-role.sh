#!/usr/bin/env bash
# deploy-role.sh — deploy or update an operational role via CloudFormation
# Usage: scripts/deploy-role.sh <role-name>
#        scripts/deploy-role.sh --all

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROLES_DIR="$PROJECT_DIR/roles"
TEMPLATE="$ROLES_DIR/_template.yaml"

# ── colors & output helpers ───────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass()  { printf "  ${GREEN}✓${NC}  %s\n" "$*"; }
fail()  { printf "\n${RED}${BOLD}[FAIL]${NC} %s\n" "$*" >&2; exit 1; }
warn()  { printf "  ${YELLOW}⚠${NC}  %s\n" "$*"; }
info()  { printf "  ${CYAN}·${NC}  %s\n" "$*"; }
step()  { echo;  printf "${BOLD}==> %s${NC}\n" "$*"; }

# ── source config.sh for tag overrides ────────────────────────────────────────
OWNER=""
ENVIRONMENT="prd"
DEPLOYMENT_ID="Default"
[[ -f "$PROJECT_DIR/config.sh" ]] && source "$PROJECT_DIR/config.sh"

# ── resolve dynamic tags ──────────────────────────────────────────────────────
PROJECT_NAME="$(basename "$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "claude-personal")"
REPOSITORY="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || echo "")"

# ── prerequisites ─────────────────────────────────────────────────────────────
check_prereqs() {
  local FAILED=0

  if ! command -v aws &>/dev/null; then
    fail "AWS CLI not found. Install: brew install awscli"
  fi

  if ! command -v jq &>/dev/null; then
    fail "jq not found. Install: brew install jq"
  fi

  if [[ -z "${AWS_SESSION_TOKEN:-}" ]]; then
    fail "No active MFA session. Run: claude-personal (to authenticate first)"
  fi

  if ! aws sts get-caller-identity &>/dev/null; then
    fail "AWS credentials invalid or expired. Start a new session."
  fi

  if [[ ! -f "$TEMPLATE" ]]; then
    fail "CloudFormation template not found: $TEMPLATE"
  fi
}

# ── resolve trusted user ARN ──────────────────────────────────────────────────
get_trusted_user_arn() {
  local ACCOUNT_ID
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
  local IAM_USER
  IAM_USER=$(security find-generic-password -a claude-bedrock -s aws-bedrock-iam-user -w 2>/dev/null || echo "")

  if [[ -z "$IAM_USER" || -z "$ACCOUNT_ID" ]]; then
    fail "Cannot determine user ARN. Ensure Keychain entries exist (run deploy.sh)."
  fi

  echo "arn:aws:iam::${ACCOUNT_ID}:user/${IAM_USER}"
}

# ── deploy a single role ──────────────────────────────────────────────────────
deploy_role() {
  local ROLE_NAME="$1"
  local ROLE_DIR="$ROLES_DIR/$ROLE_NAME"
  local POLICY_FILE="$ROLE_DIR/policy.json"
  local CONFIG_FILE="$ROLE_DIR/config.json"
  local STACK_NAME="claude-personal-role-${ROLE_NAME}"

  step "Deploying role: $ROLE_NAME"

  # Validate role directory
  if [[ ! -d "$ROLE_DIR" ]]; then
    fail "Role directory not found: $ROLE_DIR"
  fi
  if [[ ! -f "$POLICY_FILE" ]]; then
    fail "Policy file not found: $POLICY_FILE"
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    fail "Config file not found: $CONFIG_FILE"
  fi

  # Read config
  local DESCRIPTION MAX_SESSION BOUNDARY
  DESCRIPTION=$(jq -r '.description // "Claude-personal operational role"' "$CONFIG_FILE")
  MAX_SESSION=$(jq -r '.maxSessionDuration // 21600' "$CONFIG_FILE")
  BOUNDARY=$(jq -r '.permissionBoundary // ""' "$CONFIG_FILE")

  # Validate description contains only ASCII (IAM rejects non-ASCII)
  if echo "$DESCRIPTION" | grep -qP '[^\x20-\x7E]'; then
    fail "Description in $CONFIG_FILE contains non-ASCII characters. IAM only accepts printable ASCII (0x20-0x7E)."
  fi

  # Validate policy JSON
  if ! jq empty "$POLICY_FILE" 2>/dev/null; then
    fail "Invalid JSON in $POLICY_FILE"
  fi
  pass "Policy JSON valid"

  # Read policy as a compact JSON string for CloudFormation parameter
  local POLICY_DOC
  POLICY_DOC=$(jq -c '.' "$POLICY_FILE")

  # Resolve trusted user
  local TRUSTED_USER_ARN
  TRUSTED_USER_ARN=$(get_trusted_user_arn)
  info "Trusted user: $TRUSTED_USER_ARN"
  info "Stack: $STACK_NAME"
  info "Description: $DESCRIPTION"
  info "Session duration: ${MAX_SESSION}s"

  # Check if stack already exists
  local STACK_STATUS
  STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  local CF_ACTION
  if [[ "$STACK_STATUS" == "DOES_NOT_EXIST" ]]; then
    CF_ACTION="create-stack"
    info "Action: creating new stack"
  else
    CF_ACTION="update-stack"
    info "Action: updating existing stack (current status: $STACK_STATUS)"
  fi

  # Write parameters to a temp JSON file to avoid shell escaping issues with policy doc
  local PARAMS_FILE
  PARAMS_FILE=$(mktemp)
  jq -n \
    --arg roleName "$ROLE_NAME" \
    --arg trustedUser "$TRUSTED_USER_ARN" \
    --arg policyDoc "$POLICY_DOC" \
    --arg desc "$DESCRIPTION" \
    --arg maxSession "$MAX_SESSION" \
    --arg boundary "$BOUNDARY" \
    --arg owner "${OWNER:-}" \
    --arg env "$ENVIRONMENT" \
    --arg deployId "$DEPLOYMENT_ID" \
    --arg project "$PROJECT_NAME" \
    --arg repo "$REPOSITORY" \
    '[
      {ParameterKey: "RoleName", ParameterValue: $roleName},
      {ParameterKey: "TrustedUserArn", ParameterValue: $trustedUser},
      {ParameterKey: "PolicyDocument", ParameterValue: $policyDoc},
      {ParameterKey: "RoleDescription", ParameterValue: $desc},
      {ParameterKey: "MaxSessionDuration", ParameterValue: $maxSession},
      {ParameterKey: "PermissionBoundaryArn", ParameterValue: $boundary},
      {ParameterKey: "Owner", ParameterValue: $owner},
      {ParameterKey: "Environment", ParameterValue: $env},
      {ParameterKey: "DeploymentId", ParameterValue: $deployId},
      {ParameterKey: "Project", ParameterValue: $project},
      {ParameterKey: "Repository", ParameterValue: $repo}
    ]' > "$PARAMS_FILE"

  # Deploy
  local CF_OUTPUT
  CF_OUTPUT=$(aws cloudformation $CF_ACTION \
    --stack-name "$STACK_NAME" \
    --template-body "file://$TEMPLATE" \
    --parameters "file://$PARAMS_FILE" \
    --capabilities CAPABILITY_NAMED_IAM \
    --tags "Key=Name,Value=$STACK_NAME" \
           "Key=ManagedBy,Value=claude-personal-scripts" \
           "Key=Project,Value=$PROJECT_NAME" \
           "Key=Environment,Value=$ENVIRONMENT" \
    2>&1)
  local CF_STATUS=$?
  rm -f "$PARAMS_FILE"

  if [[ "$CF_STATUS" -ne 0 ]]; then
    if echo "$CF_OUTPUT" | grep -q "No updates are to be performed"; then
      pass "No changes needed — stack is up to date"
      return 0
    fi
    fail "CloudFormation $CF_ACTION failed: $CF_OUTPUT"
  fi

  # Wait for completion
  info "Waiting for stack operation to complete..."
  local WAIT_EVENT
  if [[ "$CF_ACTION" == "create-stack" ]]; then
    WAIT_EVENT="stack-create-complete"
  else
    WAIT_EVENT="stack-update-complete"
  fi

  if aws cloudformation wait "$WAIT_EVENT" --stack-name "$STACK_NAME" 2>/dev/null; then
    local ROLE_ARN
    ROLE_ARN=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
      --query 'Stacks[0].Outputs[?OutputKey==`RoleArn`].OutputValue' --output text 2>/dev/null)
    pass "Role deployed: $ROLE_ARN"
  else
    local FINAL_STATUS
    FINAL_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
      --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
    fail "Stack operation failed (status: $FINAL_STATUS). Check CloudFormation console for details."
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <role-name>|--all"
  echo ""
  echo "Available roles:"
  for dir in "$ROLES_DIR"/*/; do
    local_name=$(basename "$dir")
    [[ "$local_name" == "_example" || "$local_name" == "_template.yaml" ]] && continue
    [[ -f "$dir/policy.json" ]] || continue
    local_desc=$(jq -r '.description // "(no description)"' "$dir/config.json" 2>/dev/null || echo "(no config)")
    printf "  %-12s %s\n" "$local_name" "$local_desc"
  done
  exit 1
fi

check_prereqs

ROLE_ARG="$1"

if [[ "$ROLE_ARG" == "--all" ]]; then
  step "Deploying all roles..."
  for dir in "$ROLES_DIR"/*/; do
    name=$(basename "$dir")
    [[ "$name" == "_example" ]] && continue
    [[ -f "$dir/policy.json" ]] || continue
    deploy_role "$name"
  done
else
  deploy_role "$ROLE_ARG"
fi

echo ""
printf "${GREEN}${BOLD}Done.${NC}\n"
echo ""
if [[ "$ROLE_ARG" == "--all" ]]; then
  echo "To use a role: claude-personal --role <name>"
else
  echo "To use a role: claude-personal --role $ROLE_ARG"
fi
