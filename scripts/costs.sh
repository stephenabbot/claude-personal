#!/usr/bin/env bash
# costs.sh — show Bedrock model costs from AWS Cost Explorer
# Usage: scripts/costs.sh [--last-week | --last-month | --days N]
# Default: last 40 days

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── parse flags ──────────────────────────────────────────────────────────────

DAYS=40

while [[ $# -gt 0 ]]; do
  case "$1" in
    --last-week)  DAYS=7;  shift ;;
    --last-month) DAYS=30; shift ;;
    --days)       DAYS="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: scripts/costs.sh [--last-week | --last-month | --days N]"
      echo "Default: last 40 days"
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── compute date range ───────────────────────────────────────────────────────

if [[ "$(uname)" == "Darwin" ]]; then
  START_DATE=$(date -v-${DAYS}d +%Y-%m-%d)
  END_DATE=$(date +%Y-%m-%d)
else
  START_DATE=$(date -d "-${DAYS} days" +%Y-%m-%d)
  END_DATE=$(date +%Y-%m-%d)
fi

# ── verify credentials ───────────────────────────────────────────────────────

if ! aws sts get-caller-identity &>/dev/null; then
  printf "${YELLOW}⚠${NC}  No active AWS session. Source auth-bedrock.sh first.\n" >&2
  exit 1
fi

# ── query Cost Explorer ──────────────────────────────────────────────────────

printf "${BOLD}Bedrock costs: %s → %s${NC}\n\n" "$START_DATE" "$END_DATE"

# Discover Bedrock service names — they appear per-model, not as a single service
BEDROCK_SERVICES=$(aws ce get-dimension-values \
  --time-period Start="$START_DATE",End="$END_DATE" \
  --dimension SERVICE \
  --output json 2>&1 \
  | jq -r '.DimensionValues[].Value' \
  | grep "Bedrock Edition")

if [[ -z "$BEDROCK_SERVICES" ]]; then
  printf "${YELLOW}⚠${NC}  No Bedrock services found in this period.\n"
  printf "   Cost Explorer has a 24–48h lag — check back tomorrow if you used Bedrock recently.\n"
  exit 0
fi

# Build filter JSON from discovered service names
FILTER=$(echo "$BEDROCK_SERVICES" | jq -R -s '
  split("\n") | map(select(length > 0)) |
  {"Dimensions": {"Key": "SERVICE", "Values": .}}
')

RESULT=$(aws ce get-cost-and-usage \
  --time-period Start="$START_DATE",End="$END_DATE" \
  --granularity DAILY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --filter "$FILTER" \
  2>&1)

if [[ $? -ne 0 ]]; then
  printf "Cost Explorer query failed:\n%s\n" "$RESULT" >&2
  exit 1
fi

# ── format output ────────────────────────────────────────────────────────────

OUTPUT=$(echo "$RESULT" | jq -r '
  [.ResultsByTime[]
   | .TimePeriod.Start as $date
   | .Groups[]
   | select((.Metrics.UnblendedCost.Amount | tonumber) > 0)
   | {
       date: $date,
       model: (.Keys[0] | gsub(" \\(Amazon Bedrock Edition\\)"; "")),
       cost: (.Metrics.UnblendedCost.Amount | tonumber)
     }
  ]
  | sort_by(.date) | reverse
  | .[]
  | [.date, .model, ("$" + (.cost | tostring | if contains(".") then (split(".") | .[0] + "." + (.[1] + "0000")[0:4]) else . + ".0000" end))]
  | @tsv
')

if [[ -z "$OUTPUT" ]]; then
  printf "${YELLOW}⚠${NC}  No Bedrock costs found in this period.\n"
  printf "   Cost Explorer has a 24–48h lag — check back tomorrow if you used Bedrock recently.\n"
  exit 0
fi

# header
printf "${CYAN}%-12s  %-30s  %10s${NC}\n" "Date" "Model" "Cost"
printf "%-12s  %-30s  %10s\n" "──────────" "──────────────────────────────" "──────────"

# rows
echo "$OUTPUT" | while IFS=$'\t' read -r date model cost; do
  printf "%-12s  %-30s  %10s\n" "$date" "$model" "$cost"
done

# total
TOTAL=$(echo "$RESULT" | jq -r '
  [.ResultsByTime[].Groups[]
   | .Metrics.UnblendedCost.Amount | tonumber
  ] | add // 0
')
TOTAL_FMT=$(printf "%.4f" "$TOTAL")

printf "%-12s  %-30s  %10s\n" "──────────" "──────────────────────────────" "──────────"
printf "${BOLD}%-12s  %-30s  %10s${NC}\n" "" "Total" "\$$TOTAL_FMT"
