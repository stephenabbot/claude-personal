# TODO

### Role-based access for AWS operations (planned)
Enable Claude to act as a proxy for broader AWS account operations beyond Bedrock
invocation. The approach uses IAM AssumeRole with role selection at launch time:

- `claude-bedrock` — model invocation only (current default, unchanged)
- `claude-analyst` — broad read-only access (CloudWatch Logs, EC2 describe, S3 list, Config, IAM read, etc.)
- `claude-operator` — analyst permissions + write actions (deploy, modify, remediate)

**Implementation outline:**
- IaC definitions for each role (trust policy requires MFA, scoped to the base user)
- Role ARN mapping in config (role name → ARN)
- Launcher `--role <name>` flag to assume a role after MFA authentication
- Dual credential environment: Bedrock invocation uses base session, CLI commands use assumed role
- Permission boundaries on roles to enforce a ceiling regardless of attached policies
- Roles designed to showcase corporate adoption patterns: least privilege by default, audit trail via CloudTrail, PR-reviewed IaC, revocable without breaking base Bedrock access

### Revisit: Bedrock model access behavior with retired Model Access page
- As of 2026-05-28, AWS retired the Model Access page — models are stated to auto-enable on first invocation
- In practice, Opus 4.8 is listed in the catalog and selectable in Claude Code but retries on invocation via Bedrock
- Auto-enable may not yet be fully functional, or new models may have initial throughput ramp-up delays
- Revisit to clarify: exact activation flow, whether first-time use case submission is blocking, and whether the launcher's newer-model notification should distinguish "not yet available" from "available but throttled"
- Update docs and launcher guidance once behavior is confirmed stable

### scripts/costs.sh
- Filter by SERVICE = Amazon Bedrock; group by USAGE_TYPE (encodes model name)
- `--last-week` / `--last-month` flags; default: current month
- Formatted table: model x day with totals
- Handle all-zeros gracefully ("Cost Explorer has a 24-48h lag — check back tomorrow")
- Apply tags from config.sh to any resources created

### scripts/alarms.sh
- Create SNS topic + email subscription (requires user to confirm email)
- Create AWS Budget linked to SNS topic
- `--limit` flag for monthly spend threshold (default: $10)
- Read tag values from config.sh; apply dynamic tags (DeployedBy, Project, Repository)
- Pre-flight: check budgets + SNS permissions before attempting anything
- Update destroy.sh to clean up SNS topic and Budget on uninstall
