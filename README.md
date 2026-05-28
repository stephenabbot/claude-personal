# claude-personal

Run Claude Code on your personal Mac using AWS Bedrock — no Pro plan required.

---

## Why this exists

Claude.ai Pro is a subscription service with hard usage limits: a rolling message
quota enforced within each session window, and a 4-hour maximum session length.
When you hit either limit mid-task, Claude stops responding and your workflow is
interrupted — often at the worst possible moment. Resuming means starting a new
session, re-establishing context, and losing the flow of work.

AWS Bedrock is pay-as-you-go. There are no session time limits, no message quotas,
and no subscription. You are billed per token at rates that for personal use
typically amount to a few dollars a month. Claude Code running against Bedrock uses the same Claude models and
capabilities as Claude Pro — but without the interruptions.

---

## Approach

This project provides a small set of scripts that handle the full lifecycle:

| Script | Purpose |
|---|---|
| `scripts/deploy.sh` | One-time setup — validates prerequisites, stores credentials in macOS Keychain, installs Claude Code |
| `scripts/auth-bedrock.sh` | Sourced at session start — retrieves credentials from Keychain, prompts for MFA, exchanges for a 6-hour AWS session |
| `~/bin/claude-personal` | Launcher — checks for an active session, auto-updates Claude Code if needed, probes for the best available model, sets Bedrock env vars, launches Claude |
| `scripts/destroy.sh` | Full uninstall — removes Keychain entries, npm package, and launcher |
| `scripts/test_creds.sh` | Verification — end-to-end connectivity test from Keychain through to Bedrock |
| `config.sh` | Optional tag overrides (Owner, Environment, DeploymentId) — committed to repo, no secrets |

**Credentials never touch a plaintext file.** The permanent AWS access key and
secret are stored in macOS Keychain. The launcher uses short-lived temporary
credentials (6-hour STS session tokens) obtained only after a valid MFA code is
provided. The permanent keys alone cannot invoke any model.

---

## IAM user setup

Before running `deploy.sh` you need a dedicated IAM user in your AWS account.
Follow these steps in the AWS Console.

### 1. Create the user

- IAM → Users → **Create user**
- Username: choose any name (e.g. `a_ai`)
- Do not enable console access — this is an API-only user
- Skip group assignment — permissions are attached directly

### 2. Attach the Bedrock + STS policy

On the user page → **Add permissions** → **Create inline policy** → JSON tab.

Paste the following, then name it `bedrock_mfa_policy` and save:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowGetSessionToken",
      "Effect": "Allow",
      "Action": "sts:GetSessionToken",
      "Resource": "*"
    },
    {
      "Sid": "AllowBedrockOnlyWithMFA",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:ListFoundationModels"
      ],
      "Resource": "*",
      "Condition": {
        "Bool": {
          "aws:MultiFactorAuthPresent": "true"
        }
      }
    },
    {
      "Sid": "AllowCostExplorerReadOnlyWithMFA",
      "Effect": "Allow",
      "Action": [
        "ce:GetCostAndUsage",
        "ce:GetCostForecast",
        "ce:GetDimensionValues",
        "ce:GetUsageForecast"
      ],
      "Resource": "*",
      "Condition": {
        "Bool": {
          "aws:MultiFactorAuthPresent": "true"
        }
      }
    },
    {
      "Sid": "AllowBudgetAlertsWithMFA",
      "Effect": "Allow",
      "Action": [
        "budgets:ViewBudget",
        "budgets:ModifyBudget",
        "sns:CreateTopic",
        "sns:DeleteTopic",
        "sns:Subscribe",
        "sns:ListTopics",
        "sns:GetTopicAttributes",
        "sns:SetTopicAttributes"
      ],
      "Resource": "*",
      "Condition": {
        "Bool": {
          "aws:MultiFactorAuthPresent": "true"
        }
      }
    }
  ]
}
```

**Why four separate statements:**
`GetSessionToken` is the call that establishes an MFA-authenticated session.
The `aws:MultiFactorAuthPresent` condition key is not evaluated during this call —
it can only be evaluated on calls made *with* the resulting session token. Putting
the condition on `GetSessionToken` itself would deny the call entirely.

The MFA condition on the remaining statements ensures that the permanent access
keys alone cannot invoke models, query costs, or create alert infrastructure. Only
a temporary session obtained via MFA has access.

**Note on Cost Explorer scope:** IAM cannot restrict `ce:GetCostAndUsage` to a
specific AWS service at the policy level — the Bedrock filter is applied in the
API request itself, not enforced by IAM. However since this account is used
exclusively for Bedrock, there is nothing else to expose. The four actions granted
are read-only — no ability to modify cost categories or access billing settings.

**Note on Budgets and SNS scope:** The budget and SNS actions are used by
`scripts/alarms.sh` to create a monthly spend alert with email notification.
AWS Budgets uses a coarse permission model: `budgets:ModifyBudget` covers
create, modify, and delete operations; `budgets:ViewBudget` covers all reads.
These are scoped to budget management only — no access to billing data, cost
categories, or other AWS resources. SNS actions are similarly limited: create a
topic, subscribe an email address, and manage that topic. No ability to publish
arbitrary messages or access other SNS topics.

### 3. Enable virtual MFA

This project uses **TOTP-based MFA** (RFC 6238 — Time-based One-Time Password).
Any standard TOTP authenticator app works:

| App | Platforms |
|---|---|
| Authy | iOS, Android, Mac, Windows |
| Google Authenticator | iOS, Android |
| Microsoft Authenticator | iOS, Android |
| Apple Passwords | macOS Ventura+, iOS 17+ |
| 1Password / Bitwarden | All platforms |

> SMS-based MFA and push-notification MFA are not supported — a TOTP
> authenticator app is required.

User page → **Security credentials** → **Assign MFA device**:

1. Choose **Authenticator app**
2. Scan the QR code into your TOTP app
3. Enter two consecutive 6-digit codes to confirm enrollment
4. Note the MFA device ARN — it looks like:
   `arn:aws:iam::123456789012:mfa/your-username`
   (visible on the Security credentials tab after enrollment)

### 4. Create access keys

Security credentials tab → **Access keys** → **Create access key**:

1. Select **Local code** as the use case
2. Click through the advisory
3. **Copy both values immediately** — the secret is only shown once

### 5. Enable Bedrock and request model access

Bedrock is not enabled by default and model access must be explicitly requested
per AWS account per region.

**Enable Bedrock in your region:**
1. Open the AWS Console and switch to your target region (default: `us-east-1`)
2. Navigate to **Amazon Bedrock**
3. If prompted, click **Get started** to enable the service

**Request Claude model access:**
1. In the Bedrock console left nav → **Model access**
2. Click **Modify model access**
3. Select the Anthropic Claude models you want — recommended minimum:
   - Claude Sonnet 4.x (capable, cost-effective)
   - Claude Haiku 4.x (fast, cheapest — used for background tasks)
4. Click **Save changes** — access is typically granted within a few minutes
5. Verify: model status changes from **Available** to **Access granted**

> **Region note:** Model access is per-region. If you change `AWS_REGION` in the
> launcher you must enable model access in that region separately.
>
> **Opus note:** Some Opus models may require a brief manual review by AWS before
> access is granted — allow up to 24 hours.

Run `source scripts/test_creds.sh` after enabling access — it performs a live
invocation test to confirm models are reachable, not just listed.

---

## Installation

With the IAM user created and credentials in hand, run:

```bash
./scripts/deploy.sh
```

`deploy.sh` will:
1. Validate all prerequisites (with a colored pass/fail summary)
2. Show you exactly what it will do and ask for confirmation
3. Store credentials securely in macOS Keychain
4. Install Claude Code via npm
5. Configure `~/bin` on your PATH

---

## Usage

After setup, from any project directory:

```bash
claude-personal
```

On first run of the day you will be prompted for your TOTP MFA code.
Subsequent runs within the 6-hour session window launch immediately.

> **Tip:** TOTP codes rotate every 30 seconds. If authentication fails, wait
> for your app to show a fresh code and try again.

---

## Model selection

The launcher automatically selects the best Claude model your account has access to,
without requiring any manual configuration.

**How it works:** on first launch of a session the launcher queries Bedrock for all
available Anthropic models in your region, ranks them by capability tier
(Opus → Sonnet → Haiku), then probes each in order using a live 1-token invocation
with an 8-second timeout. The first model that responds is used. This catches both
access-denied errors (model not enabled) and throttling (model enabled but no
capacity available on a new account).

| Priority | Tier | Example models |
|---|---|---|
| 1 | Opus | Claude Opus 4.7, Opus 4.6 |
| 2 | Sonnet | Claude Sonnet 4.6, Sonnet 4.5 |
| 3 | Haiku | Claude Haiku 4.5 |

The launcher prints the selected model at startup:

```
✓  Model: us.anthropic.claude-opus-4-7
```

If Opus is not available it falls back and prints a notice:

```
⚠  Model: us.anthropic.claude-sonnet-4-6 (Opus not available — enable in Bedrock console for full capability)
```

**Newer model notifications:** when a newer model in the same tier exists in the
Bedrock catalog but is not yet enabled in your account, the launcher prints a
single yellow notice:

```
⚠  Newer model available: anthropic.claude-opus-4-8 — enable in Bedrock console → Model access
```

This only notifies within the same tier — if you are running Opus, it alerts about
newer Opus models; if running Sonnet, about newer Sonnet models. It does not suggest
upgrading to a different tier. The notification is informational only and does not
change behavior. It appears once per session (on the initial probe) and is cached
along with the model selection for the remainder of the 6-hour session.

The selected model is **cached for the duration of the 6-hour session** — the probe
runs once per session. Subsequent `claude-personal` launches within the same session
are instant. The cache clears automatically when your MFA session expires.

**To enable a newer model:** request access in the AWS Console (Bedrock → Model
access → Modify model access → enable the model), then start a new MFA session. The
probe will pick it up automatically.

> **Note on new accounts:** Bedrock cross-region inference profiles for Opus models
> have low default throughput limits that increase with usage. If Opus is selected
> but responses are slow, the launcher's 8-second probe timeout will detect this
> and fall back to Sonnet on the next session start.

**To override model selection manually:**

```bash
ANTHROPIC_MODEL=us.anthropic.claude-sonnet-4-6 claude-personal
```

Setting `ANTHROPIC_MODEL` in your environment skips the probe entirely.

---

## Resource tagging

AWS resources created by this project (SNS topics, Budgets) are tagged automatically.
The following tags are applied to every resource:

| Tag | Value | Source |
|---|---|---|
| `DeployedBy` | IAM ARN of the user running the script | `aws sts get-caller-identity` at runtime |
| `DeploymentId` | `Default` | `config.sh` override |
| `Environment` | `prd` | `config.sh` override |
| `ManagedBy` | `claude-personal-scripts` | hardcoded |
| `Name` | resource-specific | hardcoded per resource |
| `Owner` | IAM username | `config.sh` override |
| `Project` | git repository name | `git rev-parse --show-toplevel` at runtime |
| `Repository` | git remote origin URL | `git remote get-url origin` at runtime, omitted if none |

`config.sh` in the project root contains optional overrides for `Owner`, `Environment`,
and `DeploymentId`. It is committed to the repo and contains no secrets:

```bash
# Uncomment to override defaults
# OWNER="YourName"
# ENVIRONMENT="prd"
# DEPLOYMENT_ID="Default"
```

---

## Cost

Bedrock charges per token. Typical light personal usage with Claude Sonnet runs
**$1–5/month**. Opus models cost more. There are no minimum charges, no
subscription fees, and no usage outside of what you explicitly invoke.

Current Bedrock pricing: https://aws.amazon.com/bedrock/pricing/

---

## Data privacy

When you run Claude Code via this project, all inference happens through AWS Bedrock within your own
AWS account. Your prompts, responses, and conversation content never leave AWS's
Bedrock environment and are not shared with Anthropic.

**AWS Bedrock does not use API inputs or outputs to train models.** This is
contractually guaranteed and applies to all Bedrock API traffic. It is distinct
from Claude.ai (the consumer product), where Anthropic's standard data retention
and training policies apply.

| Concern | Claude.ai Pro | This project (Bedrock) |
|---|---|---|
| Where inference runs | Anthropic's infrastructure | Your private AWS account |
| Used for model training | Subject to Anthropic's policies | Never — contractually prohibited |
| Data leaves your control | Yes (routes through Anthropic) | No |
| Audit trail | Anthropic's logs | Your AWS CloudTrail (if enabled) |

This matters if you work with sensitive code, proprietary data, client information,
or operate in a regulated environment. With Bedrock, you are the data controller.

The IAM policy in this project is scoped to model invocation only — no S3, no
CloudWatch Logs, no data persistence of any kind unless you explicitly add it.
Conversations exist only in memory for the duration of the session.

Reference: [AWS Bedrock data privacy](https://aws.amazon.com/bedrock/faqs/#Data_privacy)

---

## Security model

This project was designed with a layered security posture. Each layer addresses
a distinct threat independently, so compromise of one layer does not collapse
the others.

| Layer | Threat | Mitigation |
|---|---|---|
| Credential storage | Keys stolen from disk | Stored in macOS Keychain (AES-256 encrypted at rest), never written to `~/.aws/credentials` or any plaintext file |
| Credential access | Silent exfiltration by malware | Credentials are encrypted at rest in macOS Keychain and not accessible from plaintext files — non-Keychain access by other applications triggers a macOS authorization prompt |
| Credential entry | Session recorders / screen capture | Access key, secret, and TOTP code are entered via silent input (`read -s`) — never echoed to the terminal, scrollback buffer, or session logs |
| MFA protocol | Weak second factor | TOTP (RFC 6238) is required — the industry standard rotating 6-digit code. SMS and push-notification MFA are not used |
| Network access | Keys compromised without MFA | IAM policy requires `aws:MultiFactorAuthPresent` on all Bedrock and Cost Explorer actions — permanent keys alone cannot invoke any model or query any data |
| Session lifetime | Session token intercepted | Temporary credentials expire after 6 hours and cannot be refreshed without a new MFA code |
| Blast radius | Compromised account accessing other AWS services | IAM policy grants only the minimum required actions — Bedrock invocation, model listing, Cost Explorer read, budget management, SNS topic management, and STS session token |
| Data privacy | Prompts or responses leaving the AWS account | All inference runs within your private AWS account boundary; AWS contractually does not use Bedrock API inputs/outputs for model training |
| Scope creep | Accidental resource creation | No IAM permissions exist for S3, CloudWatch, EC2, or any other service — data cannot land outside Bedrock by accident |

---

## Built with

This project was developed with the assistance of [Claude Code](https://claude.ai/code)
(Anthropic's AI coding assistant), running on AWS Bedrock — which is fitting, since
that's exactly the setup this project enables.
