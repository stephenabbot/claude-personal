#!/usr/bin/env bash
# alarms.sh — deploy or manage Bedrock spend alerts via AWS Budgets + SNS
# Usage: scripts/alarms.sh
# Interactive — no flags. Shows current settings if deployed, prompts to change.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { printf "${GREEN}✓${NC}  %s\n" "$*"; }
fail() { printf "${RED}✗${NC}  %s\n" "$*" >&2; }
warn() { printf "${YELLOW}⚠${NC}  %s\n" "$*"; }
step() { echo; printf "${BOLD}==> %s${NC}\n" "$*"; }

BUDGET_NAME="claude-personal-monthly"
TOPIC_NAME="claude-personal-alerts"

# ── load config defaults ─────────────────────────────────────────────────────

DEFAULT_THRESHOLDS="10,20,50"
DEFAULT_EMAIL=""

if [[ -f "$PROJECT_DIR/config.sh" ]]; then
  source "$PROJECT_DIR/config.sh"
fi

[[ -n "${ALARM_THRESHOLDS:-}" ]] && DEFAULT_THRESHOLDS="$ALARM_THRESHOLDS"
[[ -n "${ALARM_EMAIL:-}"      ]] && DEFAULT_EMAIL="$ALARM_EMAIL"

# ── verify credentials ───────────────────────────────────────────────────────

if ! aws sts get-caller-identity &>/dev/null; then
  fail "No active AWS session. Source auth-bedrock.sh first."
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

# ── detect existing infrastructure ──────────────────────────────────────────

step "Checking existing alarm infrastructure..."

# Check SNS topic
TOPIC_ARN=""
EXISTING_TOPICS=$(aws sns list-topics --output json 2>/dev/null || echo '{"Topics":[]}')
TOPIC_ARN=$(echo "$EXISTING_TOPICS" | jq -r ".Topics[].TopicArn" | grep ":${TOPIC_NAME}$" || echo "")

# Check email subscription
SUB_STATUS="not subscribed"
SUB_EMAIL=""
if [[ -n "$TOPIC_ARN" ]]; then
  SUBS=$(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --output json 2>/dev/null || echo '{"Subscriptions":[]}')
  SUB_EMAIL=$(echo "$SUBS" | jq -r '.Subscriptions[] | select(.Protocol=="email") | .Endpoint' | head -1)
  SUB_STATE=$(echo "$SUBS" | jq -r '.Subscriptions[] | select(.Protocol=="email") | .SubscriptionArn' | head -1)
  if [[ -n "$SUB_EMAIL" ]]; then
    if [[ "$SUB_STATE" == "PendingConfirmation" ]]; then
      SUB_STATUS="pending confirmation"
    elif [[ -n "$SUB_STATE" && "$SUB_STATE" != "null" ]]; then
      SUB_STATUS="confirmed"
    fi
  fi
fi

# Check budget
EXISTING_BUDGET=""
EXISTING_THRESHOLDS=""
BUDGET_EXISTS=0
BUDGET_JSON=$(aws budgets describe-budget --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME" --output json 2>/dev/null || echo "")
if [[ -n "$BUDGET_JSON" && "$BUDGET_JSON" != *"NotFoundException"* ]]; then
  BUDGET_EXISTS=1
  BUDGET_LIMIT=$(echo "$BUDGET_JSON" | jq -r '.Budget.BudgetLimit.Amount')
  NOTIF_JSON=$(aws budgets describe-notifications-for-budget \
    --account-id "$ACCOUNT_ID" \
    --budget-name "$BUDGET_NAME" \
    --output json 2>/dev/null || echo '{"Notifications":[]}')
  EXISTING_THRESHOLDS=$(echo "$NOTIF_JSON" | jq -r '[.Notifications[].Threshold | tostring] | sort_by(tonumber) | join(",")')
fi

# ── display current state ────────────────────────────────────────────────────

HAS_DEPLOYMENT=0
if [[ -n "$TOPIC_ARN" || "$BUDGET_EXISTS" -eq 1 ]]; then
  HAS_DEPLOYMENT=1
  echo ""
  printf "${BOLD}Current alarm settings:${NC}\n"
  echo ""

  if [[ -n "$TOPIC_ARN" ]]; then
    printf "  ${CYAN}SNS topic:${NC}   %s\n" "$TOPIC_ARN"
    if [[ -n "$SUB_EMAIL" ]]; then
      if [[ "$SUB_STATUS" == "confirmed" ]]; then
        printf "  ${CYAN}Email:${NC}       %s ${GREEN}(%s)${NC}\n" "$SUB_EMAIL" "$SUB_STATUS"
      else
        printf "  ${CYAN}Email:${NC}       %s ${YELLOW}(%s)${NC}\n" "$SUB_EMAIL" "$SUB_STATUS"
      fi
    else
      printf "  ${CYAN}Email:${NC}       ${YELLOW}none subscribed${NC}\n"
    fi
  else
    printf "  ${CYAN}SNS topic:${NC}   ${YELLOW}not found${NC}\n"
  fi

  if [[ "$BUDGET_EXISTS" -eq 1 ]]; then
    printf "  ${CYAN}Budget:${NC}      %s (limit: \$%s/month)\n" "$BUDGET_NAME" "$BUDGET_LIMIT"
    printf "  ${CYAN}Thresholds:${NC}  \$%s\n" "$(echo "$EXISTING_THRESHOLDS" | sed 's/,/, \$/g')"
  else
    printf "  ${CYAN}Budget:${NC}      ${YELLOW}not found${NC}\n"
  fi

  echo ""
  read -rp "Change settings? [y/N]: " CHANGE
  if [[ ! "$CHANGE" =~ ^[Yy]$ ]]; then
    # Offer test alert if email is confirmed
    if [[ "$SUB_STATUS" == "confirmed" ]]; then
      echo ""
      read -rp "Send a test alert? [y/N]: " DO_TEST
      if [[ "$DO_TEST" =~ ^[Yy]$ ]]; then
        aws sns publish \
          --topic-arn "$TOPIC_ARN" \
          --subject "claude-personal: test alert" \
          --message "This is a test alert from claude-personal alarms.sh. If you received this, alerts are working correctly." \
          --output text &>/dev/null \
          && ok "Test alert sent to $SUB_EMAIL" \
          || fail "Failed to send test alert"
      fi
    fi
    exit 0
  fi
fi

# ── collect settings ─────────────────────────────────────────────────────────

step "Configure alarm settings"
echo ""

# Determine defaults for prompts
if [[ "$HAS_DEPLOYMENT" -eq 1 && -n "$EXISTING_THRESHOLDS" ]]; then
  PROMPT_THRESHOLDS="$EXISTING_THRESHOLDS"
else
  PROMPT_THRESHOLDS="$DEFAULT_THRESHOLDS"
fi

if [[ "$HAS_DEPLOYMENT" -eq 1 && -n "$SUB_EMAIL" ]]; then
  PROMPT_EMAIL="$SUB_EMAIL"
else
  PROMPT_EMAIL="$DEFAULT_EMAIL"
fi

# Thresholds
if [[ -n "$PROMPT_THRESHOLDS" ]]; then
  read -rp "  Alert thresholds (comma-separated, USD) [$PROMPT_THRESHOLDS]: " INPUT_THRESHOLDS
  THRESHOLDS="${INPUT_THRESHOLDS:-$PROMPT_THRESHOLDS}"
else
  read -rp "  Alert thresholds (comma-separated, USD): " THRESHOLDS
  [[ -z "$THRESHOLDS" ]] && { fail "Thresholds are required."; exit 1; }
fi

# Email
if [[ -n "$PROMPT_EMAIL" ]]; then
  read -rp "  Alert email [$PROMPT_EMAIL]: " INPUT_EMAIL
  EMAIL="${INPUT_EMAIL:-$PROMPT_EMAIL}"
else
  read -rp "  Alert email: " EMAIL
  [[ -z "$EMAIL" ]] && { fail "Email address is required."; exit 1; }
fi

# Validate thresholds are numeric
IFS=',' read -ra THRESH_ARRAY <<< "$THRESHOLDS"
for t in "${THRESH_ARRAY[@]}"; do
  t_clean=$(echo "$t" | tr -d ' ')
  if ! [[ "$t_clean" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    fail "Invalid threshold value: $t_clean"
    exit 1
  fi
done

# ── compute tags ─────────────────────────────────────────────────────────────

DEPLOYER_ARN=$(aws sts get-caller-identity --query Arn --output text)
PROJECT_NAME=$(basename "$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "claude-personal")
REPO_URL=$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || echo "")
OWNER="${OWNER:-$(echo "$DEPLOYER_ARN" | grep -o '[^/]*$')}"
ENVIRONMENT="${ENVIRONMENT:-prd}"
DEPLOYMENT_ID="${DEPLOYMENT_ID:-Default}"

# ── deploy SNS topic ────────────────────────────────────────────────────────

step "Deploying SNS topic..."

if [[ -z "$TOPIC_ARN" ]]; then
  TOPIC_ARN=$(aws sns create-topic --name "$TOPIC_NAME" \
    --tags Key=ManagedBy,Value=claude-personal-scripts \
           Key=Project,Value="$PROJECT_NAME" \
           Key=Owner,Value="$OWNER" \
           Key=Environment,Value="$ENVIRONMENT" \
           Key=DeploymentId,Value="$DEPLOYMENT_ID" \
           Key=DeployedBy,Value="$DEPLOYER_ARN" \
           ${REPO_URL:+Key=Repository,Value="$REPO_URL"} \
    --query TopicArn --output text 2>&1)
  if [[ $? -ne 0 ]]; then
    fail "Failed to create SNS topic: $TOPIC_ARN"
    exit 1
  fi
  ok "Created SNS topic: $TOPIC_ARN"
else
  ok "SNS topic exists: $TOPIC_ARN"
fi

# ── set SNS topic policy for AWS Budgets ─────────────────────────────────────

step "Setting SNS topic policy for AWS Budgets..."

TOPIC_POLICY=$(jq -n \
  --arg arn "$TOPIC_ARN" \
  --arg acct "$ACCOUNT_ID" \
  '{
    Version: "2012-10-17",
    Statement: [{
      Sid: "AWSBudgets-notification",
      Effect: "Allow",
      Principal: {Service: "budgets.amazonaws.com"},
      Action: "SNS:Publish",
      Resource: $arn,
      Condition: {
        StringEquals: {"aws:SourceAccount": $acct},
        ArnLike: {"aws:SourceArn": ("arn:aws:budgets::" + $acct + ":*")}
      }
    }]
  }')

aws sns set-topic-attributes \
  --topic-arn "$TOPIC_ARN" \
  --attribute-name Policy \
  --attribute-value "$TOPIC_POLICY" 2>&1 \
  && ok "SNS topic policy set (AWS Budgets can publish)" \
  || { fail "Failed to set SNS topic policy"; exit 1; }

# ── manage email subscription ────────────────────────────────────────────────

NEED_CONFIRM=0

if [[ "$SUB_EMAIL" != "$EMAIL" ]]; then
  # Remove old subscription if email changed
  if [[ -n "$SUB_EMAIL" && "$SUB_STATE" != "PendingConfirmation" ]]; then
    OLD_SUB_ARN=$(echo "$SUBS" | jq -r '.Subscriptions[] | select(.Protocol=="email") | .SubscriptionArn' | head -1)
    if [[ -n "$OLD_SUB_ARN" && "$OLD_SUB_ARN" != "PendingConfirmation" ]]; then
      aws sns unsubscribe --subscription-arn "$OLD_SUB_ARN" 2>/dev/null
      ok "Removed old subscription: $SUB_EMAIL"
    fi
  fi

  # Subscribe new email
  aws sns subscribe \
    --topic-arn "$TOPIC_ARN" \
    --protocol email \
    --notification-endpoint "$EMAIL" \
    --output text &>/dev/null \
    && ok "Subscribed: $EMAIL (confirmation email sent)" \
    || { fail "Failed to subscribe $EMAIL"; exit 1; }
  NEED_CONFIRM=1
else
  if [[ "$SUB_STATUS" == "pending confirmation" ]]; then
    warn "Email $EMAIL is still pending confirmation"
    NEED_CONFIRM=1
  else
    ok "Email subscription confirmed: $EMAIL"
  fi
fi

# ── deploy budget ────────────────────────────────────────────────────────────

step "Deploying budget with thresholds..."

# Find the highest threshold to use as budget limit
MAX_THRESHOLD=0
for t in "${THRESH_ARRAY[@]}"; do
  t_clean=$(echo "$t" | tr -d ' ')
  if (( $(echo "$t_clean > $MAX_THRESHOLD" | bc -l) )); then
    MAX_THRESHOLD="$t_clean"
  fi
done

# Build notifications array
NOTIFICATIONS="["
FIRST=1
for t in "${THRESH_ARRAY[@]}"; do
  t_clean=$(echo "$t" | tr -d ' ')
  # Calculate threshold as percentage of max
  PERCENT=$(echo "scale=1; $t_clean / $MAX_THRESHOLD * 100" | bc -l)
  [[ "$FIRST" -eq 1 ]] && FIRST=0 || NOTIFICATIONS+=","
  NOTIFICATIONS+="{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":$PERCENT,\"ThresholdType\":\"PERCENTAGE\",\"NotificationState\":\"ALARM\"}"
done
NOTIFICATIONS+="]"

# Build subscribers array
SUBSCRIBERS="[{\"SubscriptionType\":\"SNS\",\"Address\":\"$TOPIC_ARN\"}]"

if [[ "$BUDGET_EXISTS" -eq 1 ]]; then
  # Update existing budget
  aws budgets update-budget \
    --account-id "$ACCOUNT_ID" \
    --new-budget "{
      \"BudgetName\": \"$BUDGET_NAME\",
      \"BudgetLimit\": {\"Amount\": \"$MAX_THRESHOLD\", \"Unit\": \"USD\"},
      \"BudgetType\": \"COST\",
      \"TimeUnit\": \"MONTHLY\",
      \"CostFilters\": {},
      \"CostTypes\": {
        \"IncludeTax\": true,
        \"IncludeSubscription\": true,
        \"UseBlended\": false,
        \"IncludeRefund\": false,
        \"IncludeCredit\": false,
        \"IncludeUpfront\": true,
        \"IncludeRecurring\": true,
        \"IncludeOtherSubscription\": true,
        \"IncludeSupport\": true,
        \"IncludeDiscount\": true,
        \"UseAmortized\": false
      }
    }" 2>&1
  if [[ $? -ne 0 ]]; then
    fail "Failed to update budget"
    exit 1
  fi

  # Delete existing notifications and recreate
  OLD_NOTIFS=$(echo "$NOTIF_JSON" | jq -c '.Notifications[]' 2>/dev/null)
  if [[ -n "$OLD_NOTIFS" ]]; then
    echo "$OLD_NOTIFS" | while IFS= read -r notif; do
      aws budgets delete-notification \
        --account-id "$ACCOUNT_ID" \
        --budget-name "$BUDGET_NAME" \
        --notification "$notif" 2>/dev/null
    done
  fi

  # Create new notifications
  for t in "${THRESH_ARRAY[@]}"; do
    t_clean=$(echo "$t" | tr -d ' ')
    PERCENT=$(echo "scale=1; $t_clean / $MAX_THRESHOLD * 100" | bc -l)
    aws budgets create-notification \
      --account-id "$ACCOUNT_ID" \
      --budget-name "$BUDGET_NAME" \
      --notification "{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":$PERCENT,\"ThresholdType\":\"PERCENTAGE\"}" \
      --subscribers "$SUBSCRIBERS" 2>/dev/null
  done

  ok "Updated budget: $BUDGET_NAME (limit: \$$MAX_THRESHOLD/month)"
else
  # Create new budget with notifications
  NOTIF_WITH_SUBS="["
  FIRST=1
  for t in "${THRESH_ARRAY[@]}"; do
    t_clean=$(echo "$t" | tr -d ' ')
    PERCENT=$(echo "scale=1; $t_clean / $MAX_THRESHOLD * 100" | bc -l)
    [[ "$FIRST" -eq 1 ]] && FIRST=0 || NOTIF_WITH_SUBS+=","
    NOTIF_WITH_SUBS+="{\"Notification\":{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":$PERCENT,\"ThresholdType\":\"PERCENTAGE\"},\"Subscribers\":$SUBSCRIBERS}"
  done
  NOTIF_WITH_SUBS+="]"

  aws budgets create-budget \
    --account-id "$ACCOUNT_ID" \
    --budget "{
      \"BudgetName\": \"$BUDGET_NAME\",
      \"BudgetLimit\": {\"Amount\": \"$MAX_THRESHOLD\", \"Unit\": \"USD\"},
      \"BudgetType\": \"COST\",
      \"TimeUnit\": \"MONTHLY\",
      \"CostFilters\": {},
      \"CostTypes\": {
        \"IncludeTax\": true,
        \"IncludeSubscription\": true,
        \"UseBlended\": false,
        \"IncludeRefund\": false,
        \"IncludeCredit\": false,
        \"IncludeUpfront\": true,
        \"IncludeRecurring\": true,
        \"IncludeOtherSubscription\": true,
        \"IncludeSupport\": true,
        \"IncludeDiscount\": true,
        \"UseAmortized\": false
      }
    }" \
    --notifications-with-subscribers "$NOTIF_WITH_SUBS" 2>&1
  if [[ $? -ne 0 ]]; then
    fail "Failed to create budget"
    exit 1
  fi
  ok "Created budget: $BUDGET_NAME (limit: \$$MAX_THRESHOLD/month)"
fi

# Display thresholds
printf "  Alerts at: "
FIRST=1
for t in "${THRESH_ARRAY[@]}"; do
  t_clean=$(echo "$t" | tr -d ' ')
  [[ "$FIRST" -eq 1 ]] && FIRST=0 || printf ", "
  printf "\$%s" "$t_clean"
done
echo ""

# ── wait for email confirmation ──────────────────────────────────────────────

if [[ "$NEED_CONFIRM" -eq 1 ]]; then
  step "Email confirmation"
  echo ""
  printf "  A confirmation email has been sent to ${BOLD}%s${NC}\n" "$EMAIL"
  printf "  Check your inbox (and spam folder) and click the confirmation link.\n"
  echo ""
  read -rp "  Poll for confirmation? The script will check every 15s (up to 5 min) [Y/n]: " WAIT_CONFIRM
  if [[ ! "$WAIT_CONFIRM" =~ ^[Nn]$ ]]; then
    printf "  Waiting for confirmation (up to 5 minutes)..."
    ELAPSED=0
    CONFIRMED=0
    while [[ $ELAPSED -lt 300 ]]; do
      sleep 15
      ELAPSED=$((ELAPSED+15))
      # Check subscription status
      CHECK_SUBS=$(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --output json 2>/dev/null)
      CHECK_ARN=$(echo "$CHECK_SUBS" | jq -r '.Subscriptions[] | select(.Protocol=="email" and .Endpoint=="'"$EMAIL"'") | .SubscriptionArn' | head -1)
      if [[ -n "$CHECK_ARN" && "$CHECK_ARN" != "PendingConfirmation" ]]; then
        CONFIRMED=1
        break
      fi
      printf "."
    done
    echo ""
    if [[ "$CONFIRMED" -eq 1 ]]; then
      ok "Email confirmed: $EMAIL"
      echo ""
      read -rp "  Send a test alert? [y/N]: " DO_TEST
      if [[ "$DO_TEST" =~ ^[Yy]$ ]]; then
        aws sns publish \
          --topic-arn "$TOPIC_ARN" \
          --subject "claude-personal: test alert" \
          --message "This is a test alert from claude-personal alarms.sh. If you received this, alerts are working correctly." \
          --output text &>/dev/null \
          && ok "Test alert sent to $EMAIL" \
          || fail "Failed to send test alert"
      fi
    else
      warn "Confirmation not received within 5 minutes."
      printf "  You can confirm later — the subscription remains pending for 72 hours.\n"
      printf "  Run scripts/alarms.sh again to check status or send a test.\n"
    fi
  else
    echo ""
    warn "Skipping confirmation wait."
    printf "  Confirm within 72 hours or the subscription expires.\n"
    printf "  Run scripts/alarms.sh again to check status.\n"
  fi
fi

# ── done ─────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════"
printf "${GREEN}${BOLD}Alarm setup complete.${NC}\n"
echo ""
printf "Budget alerts will fire when monthly spend exceeds configured thresholds.\n"
printf "View in console: https://console.aws.amazon.com/billing/home#/budgets\n"
