# Operational Roles

Each subdirectory defines an IAM role that Claude can assume via `--role <name>`.

## Structure

```
roles/
├── _template.yaml    # Shared CloudFormation template (do not edit unless extending)
├── _example/         # Copy this to create a new role
├── analyst/          # Broad read-only access
│   ├── policy.json   # IAM policy document
│   └── config.json   # Role metadata (description, session duration, boundary)
└── operator/         # Read + write access
    ├── policy.json
    └── config.json
```

## Adding a custom role

```bash
cp -r roles/_example roles/my-role
# Edit roles/my-role/policy.json (standard IAM policy format)
# Edit roles/my-role/config.json (description, duration, optional boundary)
scripts/deploy-role.sh my-role
claude-personal --role my-role
```

## Files

**policy.json** — Standard IAM policy document. Use explicit action lists (avoid
wildcards for write operations). Include `bedrock:InvokeModel` and
`bedrock:InvokeModelWithResponseStream` so Claude can continue thinking while
operating under the role.

**config.json** — Role metadata:
- `description`: shown in `list-roles.sh` and as the IAM role description
- `maxSessionDuration`: how long the assumed role session lasts (seconds, 900–43200)
- `permissionBoundary`: optional ARN of a managed policy that caps effective permissions
