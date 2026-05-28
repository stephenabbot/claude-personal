# TODO

## Done

- **launcher — model auto-selection**: probes Opus 4.7 → 4.6 → Sonnet → Haiku with 8s timeout per model; caches result for 6-hour session; warns if falling back from Opus; respects ANTHROPIC_MODEL env override
- **launcher — version comparison fix**: `--version` output stripped to bare semver before comparing with npm registry
- **launcher — bedrock-runtime fix**: corrected `aws bedrock invoke-model` → `aws bedrock-runtime invoke-model` with `fileb://` body encoding
- **test_creds.sh — bedrock-runtime fix**: same fix applied to invocation test block
- **README — IAM policy**: updated to four statements; added `AllowBudgetAlertsWithMFA` (budgets + SNS) with explanation and scope notes
- **README — security model table**: blast radius row updated to reflect budget/SNS additions
- **config.sh**: created with Owner/Environment/DeploymentId overrides; committed to repo (no secrets); renamed from config.env to avoid `.env` anti-pattern
- **README — data privacy section**: added — Bedrock vs Claude.ai comparison table, contractual guarantee, IAM scope note, AWS FAQ reference
- **deploy.sh — launcher heredoc synced**: switched to quoted heredoc delimiter (`'LAUNCHER_SCRIPT'`); now matches production launcher exactly (bedrock-runtime, fileb://, 8s probe timeout, quota-safe loop, version comparison fix, model status messages)
- **deploy.sh — Bedrock pre-flight check**: probes haiku/sonnet with bedrock-runtime in audit phase; pass/warn with remediation instructions
- **deploy.sh — version comparison fix**: audit phase now strips `v2.x.x (Claude Code)` to bare semver before comparing with npm registry
- **README — model selection**: updated to reflect actual probe behaviour (8s timeout, opus-4-7→4-6→sonnet→haiku order, new account throttling note, correct model IDs and warning message format)
- **README — tagging section**: added resource tagging table and config.sh documentation
- **README — approach table**: updated launcher description; added config.sh entry

---

## Pre-publish (do now)

### Git commit + push to public GitHub

---

## Post-publish (after usage data accumulates)

### scripts/costs.sh
- Filter by SERVICE = Amazon Bedrock; group by USAGE_TYPE (encodes model name)
- `--last-week` / `--last-month` flags; default: current month
- Formatted table: model × day with totals
- Handle all-zeros gracefully ("Cost Explorer has a 24–48h lag — check back tomorrow")
- Apply tags from config.env to any resources created

### scripts/alarms.sh
- Create SNS topic + email subscription (requires user to confirm email)
- Create AWS Budget linked to SNS topic
- `--limit` flag for monthly spend threshold (default: $10)
- Read tag values from config.env; apply dynamic tags (DeployedBy, Project, Repository)
- Pre-flight: check budgets + SNS permissions before attempting anything
- Update destroy.sh to clean up SNS topic and Budget on uninstall

### IAM policy — apply budget/SNS statement to live account
- README already updated with `AllowBudgetAlertsWithMFA` statement
- Live `a_bedrock_user` policy still has the old three-statement version
- Update via CLI when alarms.sh is ready to test

### z_initial-setup-instructions.md — refresh
- Remove stale hardcoded model IDs
- Update invocation examples to use `aws bedrock-runtime` (not `aws bedrock`)
- Reflect dynamic model selection behaviour
- Add config.env tagging section
