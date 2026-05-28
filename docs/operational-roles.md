# Operational Roles

Grant Claude scoped authority to act as your proxy for AWS operations beyond model
invocation — log analysis, resource inspection, configuration audit, and (optionally)
resource modification.

---

## The problem

Claude Code is a capable engineering assistant, but by default it has zero AWS
authority beyond invoking Bedrock models. Every `aws` command it attempts to run on
your behalf fails. The value multiplier of having an AI agent that can inspect your
infrastructure, analyze logs, and diagnose issues is locked behind "I'll just do it
myself."

## The approach

Operational roles use IAM AssumeRole to grant Claude explicit, scoped, time-limited
authority:

- **Identity stays narrow** — the base user (`a_bedrock_user`) authenticates via MFA
  and can only invoke Bedrock + assume designated roles
- **Roles define authority** — each role is a CloudFormation stack with an explicit
  policy document, deployed and versioned alongside the project
- **MFA required** — the trust policy on every role requires an active MFA session;
  permanent keys alone cannot assume any role
- **Session-scoped** — assumed role credentials have their own expiry (configurable
  per role, default 6 hours for analyst, 1 hour for operator)

---

## Quick start

```bash
# 1. Deploy the analyst role (one-time)
scripts/deploy-role.sh analyst

# 2. Launch Claude with the role
claude-personal --role analyst

# Claude can now read your AWS account: logs, resources, config, costs
```

---

## Shipped roles

### analyst

**Scope:** Broad read-only access across common AWS services.

| Service | Access |
|---|---|
| CloudWatch Logs | Read log groups, streams, events; run Insights queries |
| EC2 | Describe all resources |
| S3 | List buckets, read objects, read policies |
| IAM | Read users, roles, policies (no modification) |
| Lambda | Read function config and code |
| CloudFormation | Read stacks, resources, templates |
| DynamoDB | Read tables, query/scan items |
| SNS | Read topics and subscriptions |
| CloudFront | Read distributions |
| Route53 | Read zones and records |
| CloudTrail | Look up events |
| Cost Explorer | Read cost and usage data |
| Config | Read compliance rules |
| SSM Parameter Store | Read parameters |
| Support | Trusted Advisor check results |
| Bedrock | Invoke models (so Claude can continue thinking) |

**Session duration:** 6 hours (matches the MFA session).

**Use cases:** "What's in these CloudWatch logs?", "Audit this account's IAM
configuration", "What's our Lambda error rate?", "Walk me through the CloudFormation
stacks."

### operator

> **WARNING: This role grants full administrator access (`Action: *`, `Resource: *`).
> It can create, modify, and delete any resource in your AWS account. Use only when
> you fully understand the implications and actively supervise Claude's actions.
> See the [liability disclaimer](#disclaimer) at the bottom of this document.**

**Scope:** Unrestricted — equivalent to AWS `AdministratorAccess`.

**Session duration:** 1 hour (intentionally short to limit exposure window).

**Why full access:** In practice, real operational work regularly exceeds any
predefined action list. A narrowly scoped operator role creates friction without
meaningful security improvement when the user is already supervising Claude's
actions in real time. The short session duration and MFA requirement provide the
actual guardrails.

**Use cases:** "Deploy this infrastructure", "Fix this misconfiguration",
"Investigate and remediate this issue", "Set up this new service."

**Mitigations:**
- 1-hour session duration limits the blast radius window
- MFA required — cannot be assumed without active user authentication
- CloudTrail logs every action for full auditability
- Use `permissionBoundary` in config.json to cap effective permissions if needed
- Consider creating a custom narrower role for production environments

---

## Creating a custom role

```bash
# 1. Copy the example
cp -r roles/_example roles/my-role

# 2. Edit the policy (standard IAM policy document)
$EDITOR roles/my-role/policy.json

# 3. Edit the config (description, session duration, optional boundary)
$EDITOR roles/my-role/config.json

# 4. Deploy
scripts/deploy-role.sh my-role

# 5. Use
claude-personal --role my-role
```

### config.json fields

| Field | Required | Default | Description |
|---|---|---|---|
| `description` | yes | — | Human-readable purpose of the role |
| `maxSessionDuration` | no | 21600 | Maximum session length in seconds (900–43200) |
| `permissionBoundary` | no | `""` | ARN of a permission boundary to cap this role |

### Narrowing a role

Edit `policy.json` to remove actions or restrict `Resource` from `"*"` to specific
ARNs. Then re-run `scripts/deploy-role.sh <name>` — the stack updates in place.

### Permission boundaries

Set `permissionBoundary` in `config.json` to an existing IAM managed policy ARN.
The boundary acts as a ceiling — even if the policy grants broad access, the
effective permissions are the intersection of the policy and the boundary.

---

## Managing roles

```bash
# List all defined roles and their deployment status
scripts/list-roles.sh

# Deploy or update a specific role
scripts/deploy-role.sh analyst

# Deploy all defined roles
scripts/deploy-role.sh --all

# Delete a role (prompts for confirmation)
scripts/destroy-role.sh analyst
```

---

## Corporate adoption patterns

This role-based model maps directly to how enterprises manage AI agent access:

### Least privilege by default

The default `claude-personal` invocation has zero AWS operational access. Roles are
opt-in per session — you explicitly choose what authority Claude has when you launch.

### Full audit trail

Every action Claude takes under an assumed role is logged in CloudTrail with the
role session name `claude-personal-<role>-<timestamp>`. You can trace exactly what
the AI did, when, and under which role.

### Governance via code review

Role policies are JSON files in version control. Adding or expanding a role is a PR
— reviewable, commentable, approvable by the security team before deployment.

### Separation of identity and authorization

The base user authenticates (MFA). Roles authorize. Revoking a role (deleting its
stack) doesn't break authentication or Bedrock access — it only removes that
specific operational capability.

### Service Control Policies as a backstop

For organizations using AWS Organizations, SCPs can cap what any role in the account
can do regardless of its attached policy. The roles in this project compose cleanly
with SCP-based guardrails.

### Independent lifecycle

Each role is its own CloudFormation stack. Add, update, or delete roles without
affecting others. No monolithic policy to coordinate across teams.

---

## Architecture decisions

| Decision | Rationale |
|---|---|
| CloudFormation (not Terraform) | Self-contained — no external state backend needed. Clone the project, deploy roles. |
| Per-role stacks | Independent lifecycle. Deleting one role doesn't risk others. |
| Directory-based role definitions | Extensible without code changes. Copy a directory to add a role. |
| Policy as separate JSON file | Familiar IAM policy format. Reviewable in PRs. Testable with IAM Policy Simulator. |
| MFA in trust policy | Defense in depth — even if AssumeRole permission is misconfigured, the role refuses non-MFA sessions. |
| Bedrock actions in every role | The assumed role handles both CLI operations and model invocation — one credential set, one audit identity. |

---

## Prerequisites

### Permissions for deploying roles

`deploy-role.sh` creates CloudFormation stacks containing IAM roles. This requires
elevated permissions beyond the base Bedrock policy — specifically
`cloudformation:*` and `iam:*` scoped to `claude-personal-role-*` resources, or
equivalent administrator access. The base user's policy intentionally does not
include these actions.

**Options:**
- Temporarily grant your IAM user admin access while deploying roles, then remove it
- Create a scoped deployment policy for CloudFormation + IAM operations
- Use a separate admin account/role to run `deploy-role.sh`

Role deployment is a one-time operation (or whenever you update a policy). Day-to-day
usage (`claude-personal --role analyst`) only requires `sts:AssumeRole`.

### Base user policy update for assuming roles

The base user needs `sts:AssumeRole` permission scoped to the project's role naming
pattern. Add this statement to the existing `bedrock_mfa_policy`:

```json
{
  "Sid": "AllowAssumeOperationalRoles",
  "Effect": "Allow",
  "Action": "sts:AssumeRole",
  "Resource": "arn:aws:iam::<your-account-id>:role/claude-personal-role-*",
  "Condition": {
    "Bool": {
      "aws:MultiFactorAuthPresent": "true"
    }
  }
}
```

This permits assuming only roles matching the `claude-personal-role-*` pattern, and
only from an MFA-authenticated session.

---

## Disclaimer

**USE AT YOUR OWN RISK.** This project and its operational roles — particularly the
`operator` role which grants unrestricted administrator access — are provided "as is"
without warranty of any kind, express or implied. The author(s) of this project
accept no responsibility or liability for any damage, data loss, service disruption,
financial charges, security incidents, or any other adverse outcomes resulting from
the use of this software.

By deploying and using these roles, you acknowledge that:

1. You understand the permissions being granted and their implications
2. You are solely responsible for the actions taken under these roles, whether
   initiated by you directly or by an AI agent acting on your behalf
3. AI agents can and do make mistakes — they may misinterpret instructions, take
   unintended actions, or cause unintended consequences
4. You accept full responsibility for supervising, reviewing, and approving all
   actions taken within your AWS account
5. You are responsible for implementing appropriate safeguards (permission
   boundaries, SCPs, billing alarms, CloudTrail monitoring) suitable to your
   environment

This project is intended for educational and personal use. If you are deploying in a
corporate or production environment, consult your organization's security and
compliance teams before proceeding.
