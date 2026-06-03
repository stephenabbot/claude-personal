# config.sh — optional tag overrides for AWS resources created by this project
#
# All values below have sensible defaults and do not need to be changed for
# standard personal use. Uncomment and edit only what you want to override.
#
# This file is committed to the repo — it contains no secrets.
# Dynamic tags (DeployedBy, Project, Repository) are always computed at
# runtime and cannot be overridden here.

# OWNER="YourName"        # default: IAM username of the deploying user
# ENVIRONMENT="prd"       # default: prd
# DEPLOYMENT_ID="Default" # default: Default

# ── Alarm settings (scripts/alarms.sh) ──────────────────────────────────────
# ALARM_THRESHOLDS="10,20,50"  # default: 10,20,50 — comma-separated USD values
# ALARM_EMAIL=""               # required for alarms — no default
