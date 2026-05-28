# TODO

### Role-based access — post-implementation
- Test with permission boundaries to confirm intersection behavior
- Consider adding a `claude-admin` role for accounts where full access is appropriate
- Add role assumption to the deploy.sh audit phase (check if roles are deployed)

### Revisit: Bedrock model access behavior with retired Model Access page
- As of 2026-05-28, AWS retired the Model Access page — models are stated to auto-enable on first invocation
- However, Opus 4.8 returns `AccessDeniedException` with: "not available for this account... contact AWS Sales"
- This means some models (likely higher-tier Opus) require a sales engagement, NOT auto-enable
- The current notification text "try invoking in Bedrock console to activate" is misleading for this class of model
- Need to distinguish between: (a) auto-enabled models, (b) use-case-submission models, (c) sales-gated models
- Consider updating notification to be more neutral: "not yet accessible — check Bedrock console for details"
- Revisit once the new access model stabilizes and the distinction is clearer

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
