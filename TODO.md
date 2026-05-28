# TODO

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
