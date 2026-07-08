# TODO

## restructure claude

## Role-based access — post-implementation

- Test with permission boundaries to confirm intersection behavior
- Consider adding a `claude-admin` role for accounts where full access is appropriate
- Add role assumption to the deploy.sh audit phase (check if roles are deployed)

## Revisit: Bedrock model access behavior with retired Model Access page

- As of 2026-05-28, AWS retired the Model Access page — models are stated to auto-enable on first invocation
- However, Opus 4.8 returns `AccessDeniedException` with: "not available for this account... contact AWS Sales"
- This means some models (likely higher-tier Opus) require a sales engagement, NOT auto-enable
- The current notification text "try invoking in Bedrock console to activate" is misleading for this class of model
- Need to distinguish between: (a) auto-enabled models, (b) use-case-submission models, (c) sales-gated models
- Consider updating notification to be more neutral: "not yet accessible — check Bedrock console for details"
- Revisit once the new access model stabilizes and the distinction is clearer

## claude.md refactor notes

Here is a comprehensive breakdown of how Claude Code manages hierarchical instruction files, based on official Anthropic documentation and practitioner-documented patterns.
CLAUDE.md Load Order & Precedence

Claude Code uses a five-tier precedence chain that determines which instructions apply when conflicts arise. From highest to lowest priority:
Priority Source Location
1 (highest) Managed policy macOS: /Library/Application Support/ClaudeCode/CLAUDE.md; Linux: /etc/claude-code/CLAUDE.md
2 CLI arguments --append-system-prompt and session flags
3 Local overrides ./CLAUDE.local.md or .claude/settings.local.json
4 Project instructions ./CLAUDE.md or ./.claude/CLAUDE.md
5 (lowest) User instructions ~/.claude/CLAUDE.md

Critically, files are concatenated, not overridden — all CLAUDE.md files in the directory tree are loaded and merged into context. Claude walks up from your working directory, so running from foo/bar/ loads foo/bar/CLAUDE.md, then foo/CLAUDE.md, then ~/.claude/CLAUDE.md. Parent files appear in context before child files, meaning the more-specific file (closer to your working dir) is read last, effectively getting the final word in cases of ambiguity.

Subdirectory CLAUDE.md files under your working directory are lazy-loaded on demand when Claude reads files in those subdirectories — they don't consume context at startup.
Mid-Session Supplemental Loading

Several officially supported mechanisms allow supplemental instruction injection:

    @path/to/file imports inside CLAUDE.md: Expanded and loaded into context at launch. Supports relative and absolute paths, up to 4 hops of recursive imports. Example: - git workflow @docs/git-instructions.md

    .claude/rules/ directory: Markdown files placed here load alongside CLAUDE.md at startup. Path-scoped rules (using YAML frontmatter paths:) only activate when Claude opens matching files — e.g., rules for src/api/**/*.ts fire only when editing API TypeScript files

    Skills (.claude/skills/): On-demand workflows loaded via /skill-name command or auto-invoked when Claude matches the skill's description frontmatter to your prompt — they do NOT load at startup, preserving context budget

    --add-dir flag + CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1: Lets you load CLAUDE.md from external directories outside the main project tree

    /memory command: Lists all currently loaded instruction files and lets you toggle or edit them mid-session

Scope-Based Conditional Loading

Path-scoped rules are the primary officially supported pattern for conditional loading based on file type, language, or framework:

text
---

paths:

- "src/api/**/*.ts"

---

# API Development Rules

- All endpoints must include input validation

Glob pattern options include **/*.ts, src/**/*, *.md, and brace expansion like src/**/*.{ts,tsx}. Rules without a paths field load unconditionally. This maps cleanly to your use case — you can have separate rule files for Go vs TypeScript, AWS vs GCP, or React vs Vue that only consume context when relevant.

For cross-project shared rules, symlinks are officially supported:

bash
ln -s ~/shared-claude-rules .claude/rules/shared

File Organization Patterns

The practitioner consensus has converged on this directory structure:

text
your-project/
├── CLAUDE.md                     # Root project instructions (<200 lines)
├── CLAUDE.local.md               # Personal overrides (gitignored)
└── .claude/
    ├── CLAUDE.md                 # Alt location for project instructions
    ├── rules/
    │   ├── code-style.md         # Always-loaded style rules
    │   ├── testing.md            # Always-loaded test conventions
    │   └── api-design.md         # Path-scoped (e.g., paths: src/api/**)
    ├── skills/
    │   └── code-review/
    │       └── SKILL.md          # On-demand workflow
    ├── agents/
    │   └── security-auditor.md   # Specialist subagent persona
    ├── docs/
    │   └── architecture.md       # Reference docs (loaded by skills, not globally)
    └── settings.json             # Permissions

~/.claude/
├── CLAUDE.md                     # Personal prefs, all projects
├── rules/
│   ├── preferences.md
│   └── workflows.md
└── skills/                       # Personal skills, all projects

Key naming/size conventions from practitioners:

    Root CLAUDE.md: under 200 lines (Anthropic official), ideally under 100 (community consensus)

    Rules files: one concern per file, named descriptively (testing.md, api-design.md)

    Skills: subdirectory per skill, SKILL.md as the entrypoint — filenames using lowercase letters, numbers, hyphens only (max 64 chars)

    CLAUDE.local.md must be added to .gitignore; settings.local.json is auto-gitignored by Claude Code

The community pattern of a .claude/docs/ folder for reference material loaded only by skills (not globally) is popular but not officially documented — it's an emergent convention to avoid bloating global context.
Official vs. Experimental Practices
Practice Status
Five-level precedence chain (Managed > CLI > Local > Project > User) ✅ Official (
code.claude.com/docs/en/memory
)
CLAUDE.local.md for personal gitignored overrides ✅ Official
.claude/rules/ with path-scoped YAML frontmatter ✅ Official
@path/to/file import syntax in CLAUDE.md ✅ Official
Skills (SKILL.md) for on-demand workflows ✅ Official
claudeMdExcludes in settings for monorepo filtering ✅ Official
.claude/docs/ folder for reference material ⚠️ Experimental/Community (not in official docs)
Symlinked ~/.claude/rules/ shared across projects ✅ Official
CLAUDE.md as a "routing file" under 150 lines pointing to rules ⚠️ Community best practice (not mandated)
Auto-memory (MEMORY.md) via /memory system ✅ Official (requires Claude Code v2.1.59+)
Explicit References

    Official memory/CLAUDE.md docs:
    code.claude.com/docs/en/memory

    Settings hierarchy (official + community):
    agentfactory.panaversity.org/docs/.../settings-hierarchy

    Anatomy of the .claude folder (deep practitioner guide):
    codewithmukesh.com/blog/anatomy-of-the-claude-folder/

    Ultimate Guide to CLAUDE.md 2026:
    buildcamp.io/guides/the-ultimate-guide-to-claudemd

    Community project structure discussion (Reddit r/ClaudeAI):
    reddit.com/r/ClaudeAI/comments/1r66oo0

    Claude Code CLI cheat sheet with commands:
    shipyard.build/blog/claude-code-cheat-sheet/

    GitHub best practices repo:
    github.com/shanraisshan/claude-code-best-practice

    Best Claude Code skills directory 2026:
    developersdigest.tech/blog/best-claude-code-skills-2026

ty, now, I am curious, is there a difference to priority given to shared information that may be conflicting? - ie is the first stateemnt given priority over the last statement - to help clarify the ask, imaging there are 1k lines between the 1st and last statement in a collection of statments, which one is more likely - ignoring other factors like other information that may impact the estimated accuracy or priority of the two statements - which is most likely to be considered the one to use?

This is a nuanced question that blends two separate but related phenomena — so it's worth unpacking them clearly.
The Short Answer: Last statement wins — but with caveats

Within a single, flat block of text (like one CLAUDE.md file), the later statement generally takes precedence when there is a direct conflict, due to what researchers call recency bias. The transformer attention mechanism gives more weight to tokens closer to the end of the input, which effectively means a "use tabs" rule at line 800 will more likely override a "use spaces" rule at line 50.
The "Lost in the Middle" Complication

However, the question at 1,000 lines triggers a more serious effect: the "Lost in the Middle" problem. Introduced by Liu et al. (2023), this is the key nuance:

    When context is less than ~50% full: tokens buried in the middle of the context are deprioritized by attention — both the first and last statements get more weight than a conflicting one at line 500

    When context is greater than ~50% full: recency bias sharpens, and the earliest tokens (primacy) actually start dropping out first — the last statement becomes dominant

So in your 1,000-line scenario with two conflicting statements and nothing else, the attention mechanics look roughly like this:

text
Line 1 statement:    HIGH attention (primacy)
Lines 2–999:         Degrading attention (lost in middle)
Line 1000 statement: HIGHEST attention (recency dominates)

The last statement is most likely to be followed, but the first statement is still meaningfully attended to. Both beat whatever is in the middle.
Why This Matters Practically for CLAUDE.md

Anthropic's own documentation treats CLAUDE.md as context, not a strict rule enforcer — Claude will try to follow all instructions but there is no deterministic compliance guarantee, especially with conflicting ones. Practitioners have confirmed that phrasing strength (e.g., ALWAYS, NEVER, CRITICAL) matters more than position in many cases.

The practical implications for your CLAUDE.md authoring:

    Put the most important, non-negotiable rules last to leverage recency bias

    Use strong modal keywords (ALWAYS, NEVER, MUST) on any rule that absolutely cannot be violated — this acts as an attention signal independent of position

    Keep files short (under ~150 lines) precisely to avoid the lost-in-the-middle zone

    For truly conflicting rules, don't rely on ordering at all — eliminate the conflict explicitly, or use path-scoped rules to make each statement conditionally non-conflicting

I now how a reminder document in my local project to describe my situation, and considered approach for when I have time to resume:

# Claude Instructions Refactor — Problem, Research, and Solutions

**Date**: 2026-06-08  
**Context**: Working session on improving Claude Code operational instruction management

---

## Problem Statement

### Current State

- Single `~/CLAUDE.md` file (2,277 bytes) provides baseline operational requirements for all Claude sessions
- File serves as minimal guardrails: critical advisor role, epistemic standards, communication preferences, AWS account awareness, code change authorization protocols

### Identified Gap

Need for **layered instruction hierarchy** to support:

1. **Generic/common workflows** — reusable across many (but not all) sessions
2. **Session-specific guidance** — temporary, context-dependent instructions
3. **Project-specific overrides** — local requirements that supersede global defaults

### Requirements for Solution

- Self-documenting
- Minimal verbosity
- Clear precedence hierarchy (more-specific overrides more-generic)
- Obvious and maintainable invocation patterns

---

## Research Findings

### Load Order & Precedence (Official)

From Anthropic documentation and practitioner analysis:

**Five-tier precedence chain** (highest to lowest):

1. Managed policy (`/Library/Application Support/ClaudeCode/CLAUDE.md` or `/etc/claude-code/CLAUDE.md`)
2. CLI arguments (`--append-system-prompt`, session flags)
3. Local overrides (`./CLAUDE.local.md`, `.claude/settings.local.json`)
4. Project instructions (`./CLAUDE.md` or `./.claude/CLAUDE.md`)
5. User instructions (`~/.claude/CLAUDE.md`)

**Critical behavior**: Files are **concatenated, not overridden**

- Claude walks up from working directory
- Parent files load before child files in context
- More-specific (closer to working dir) gets "final word" in ambiguous cases
- Example: working in `/Users/CN462662/projects/temp/` loads:
  1. `./CLAUDE.md` (project-local)
  2. `~/CLAUDE.md` (user global)
  - Project-local appears first in context, user global second → **project gets final word**

### Supplemental Loading Mechanisms (Official)

1. **`@path/to/file` imports** — inside CLAUDE.md, expanded at launch
   - Supports relative/absolute paths
   - Up to 4 hops of recursive imports
   - Example: `@docs/git-instructions.md`

2. **`.claude/rules/` directory** — markdown files load alongside CLAUDE.md at startup
   - **Path-scoped rules** via YAML frontmatter activate only when matching files opened:

     ```yaml
     ---
     paths:
       - "src/api/**/*.ts"
     ---
     # API Development Rules
     ```

   - Glob patterns: `**/*.ts`, `src/**/*,`*.md`, brace expansion`src/**/*.{ts,tsx}`
   - Rules without `paths:` field load unconditionally

3. **`.claude/skills/` directory** — on-demand workflows
   - Subdirectory per skill with `SKILL.md` entrypoint
   - Invoked via `/skill-name` command
   - Auto-matched when Claude detects description frontmatter relevance
   - **Zero context cost until invoked** — critical for preserving context budget

4. **`--add-dir` flag** + `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`
   - Load CLAUDE.md from external directories outside project tree

5. **`/memory` command** — lists loaded instruction files, allows toggle/edit mid-session

### Subdirectory Behavior

CLAUDE.md files in subdirectories under working directory are **lazy-loaded on demand** when Claude reads files in those subdirectories — don't consume context at startup.

---

## Attention Mechanics & Conflict Resolution

### Recency Bias (Research: Liu et al. 2023, "Lost in the Middle")

When conflicting statements exist within a single flat text block (e.g., one CLAUDE.md file):

**Last statement wins** — but with caveats:

- **Context <50% full**: Tokens in middle deprioritized; first AND last statements get more weight than middle
- **Context >50% full**: Recency bias sharpens; earliest tokens drop first; **last statement becomes dominant**

**In 1,000-line file with two conflicts**:

```
Line 1 statement:    HIGH attention (primacy)
Lines 2–999:         Degrading attention (lost in middle)
Line 1000 statement: HIGHEST attention (recency dominates)
```

### Practical Implications

1. **Position non-negotiables at end** to leverage recency bias
2. **Use strong modal keywords** (ALWAYS, NEVER, MUST, CRITICAL) — acts as attention signal independent of position
3. **Keep files short** (<150 lines recommended; <200 lines official limit) to avoid lost-in-middle zone
4. **Eliminate conflicts explicitly** rather than relying on ordering — or use path-scoped rules to make statements conditionally non-conflicting

### Tension with Current `~/CLAUDE.md` Structure

Current file opens with Role/Communication (foundational) and ends with Requirements Refinement (tactical). If last-wins holds, **interrupt protocol and epistemic standards** (middle-positioned, load-bearing) may be deprioritized relative to 2-question limit at end.

---

## Recommended File Organization Pattern

From practitioner consensus:

```
your-project/
├── CLAUDE.md                     # Root project instructions (<200 lines)
├── CLAUDE.local.md               # Personal overrides (gitignored)
└── .claude/
    ├── CLAUDE.md                 # Alt location for project instructions
    ├── rules/
    │   ├── code-style.md         # Always-loaded style rules
    │   ├── testing.md            # Always-loaded test conventions
    │   └── api-design.md         # Path-scoped (e.g., paths: src/api/**)
    ├── skills/
    │   └── code-review/
    │       └── SKILL.md          # On-demand workflow
    ├── agents/
    │   └── security-auditor.md   # Specialist subagent persona
    ├── docs/
    │   └── architecture.md       # Reference docs (loaded by skills, not globally)
    └── settings.json             # Permissions


~/.claude/
├── CLAUDE.md                     # Personal prefs, all projects
├── rules/
│   ├── preferences.md
│   └── workflows.md
└── skills/                       # Personal skills, all projects
```

### Naming Conventions

- Root CLAUDE.md: <200 lines (official), <100 lines (community consensus)
- Rules files: one concern per file, descriptive names (`testing.md`, `api-design.md`)
- Skills: lowercase letters, numbers, hyphens only (max 64 chars)
- `CLAUDE.local.md` must be in `.gitignore`
- `settings.local.json` auto-gitignored by Claude Code

---

## Solution Approaches for Identified Needs

### 1. Generic/Common Workflows (e.g., compound AWS commands)

**Recommended**: `.claude/skills/`

- Each workflow = subdirectory with `SKILL.md`
- Invoke via `/skill-name` or auto-matched by description
- Self-documenting (filename = invocation)
- Zero context cost until needed

**Example**:

```
~/.claude/skills/aws-account-switch/SKILL.md
~/.claude/skills/terraform-apply-protocol/SKILL.md
```

### 2. Session-Specific Guidance

**Recommended**: `CLAUDE.local.md` in project root

- Highest precedence of project-level files
- Gitignored by default
- Temporary overrides without polluting project history

### 3. Context-Dependent Rules (language/framework/cloud-specific)

**Recommended**: Path-scoped rules in `.claude/rules/`

**Example** — AWS-specific rules only when working with Terraform:

```yaml
# .claude/rules/aws-ops.md
---
paths:
  - "*.tf"
  - "*.tfvars"
---
# AWS Operations Protocol
- ALWAYS confirm account alias before destructive operations
- NEVER use wildcards in resource deletion commands
```

### 4. Cross-Project Shared Rules

**Official support**: Symlinks

```bash
ln -s ~/.claude/shared-rules .claude/rules/shared
```

---

## Refactoring Strategy for Current `~/CLAUDE.md`

### Current Issues

1. **Monolithic** — all concerns in one file increases lost-in-middle risk
2. **Ordering** — most critical rules (AWS account awareness, no unauthorized destructive ops) positioned mid-file
3. **No path-scoping** — AWS rules apply universally even when not relevant

### Proposed Restructure

**Keep in `~/CLAUDE.md`** (<150 lines, critical-only):

```markdown
# Role & Communication (foundational framing)
...


# CRITICAL PROTOCOLS (move to end, use MUST/NEVER)
## Epistemic Standards
- MUST verify load-bearing facts against primary authority before asserting
- MUST state confidence level when not high


## Interrupts
- MUST respond with *"I have a concern or question please..."* when detecting high-risk action


## Code Changes
- MUST obtain explicit authorization before proposing code changes
- MUST obtain explicit authorization before implementing code changes


## AWS Account Awareness
- MUST confirm active AWS account alias before AWS operations
- NEVER run force push to main/master
- NEVER skip hooks unless explicitly requested
```

**Extract to `.claude/rules/`**:

- `~/.claude/rules/aws-operations.md` (path-scoped to `*.tf`, AWS CLI scripts)
- `~/.claude/rules/git-protocols.md` (path-scoped to repos with `.git/`)
- `~/.claude/rules/python-env.md` (path-scoped to `*.py`, pyenv-specific)

**Extract to `.claude/skills/`**:

- `~/.claude/skills/aws-account-switch/SKILL.md`
- `~/.claude/skills/terraform-review/SKILL.md`

---

## Next Steps When Resuming

1. **Audit current `~/CLAUDE.md`**:
   - Identify absolute non-negotiables vs. contextual preferences
   - Mark rules that should be path-scoped

2. **Test precedence empirically**:
   - Create conflicting instruction in `/Users/CN462662/projects/temp/CLAUDE.md`
   - Observe which wins in practice

3. **Implement restructure**:
   - Rewrite `~/CLAUDE.md` with critical-only rules at end
   - Create `.claude/rules/` for extracted concerns
   - Create `.claude/skills/` for compound workflows

4. **Validate**:
   - Confirm path-scoped rules activate correctly
   - Test skill invocation patterns
   - Monitor context budget impact

---

## Reference Materials

**Research on attention mechanics**:

- Liu et al. (2023): "Lost in the Middle" — recency bias in long-context transformers

**Official Documentation**:

- code.claude.com/docs/en/memory

**Practitioner Guides**:

- codewithmukesh.com/blog/anatomy-of-the-claude-folder/
- buildcamp.io/guides/the-ultimate-guide-to-claudemd
- github.com/shanraisshan/claude-code-best-practice

**Session Context**:

- Working directory: `/Users/CN462662/projects/temp`
- Current AWS account: `cnc-aws-cess-dev-arc1` (843859520205)
- User: CN462662, role: LZ_DevOps

---

## Key Insights to Preserve

1. **Files concatenate, don't override** — all CLAUDE.md files in tree load together
2. **Last wins on conflict** — but only when files are long enough to trigger lost-in-middle
3. **Skills are zero-cost until invoked** — ideal for workflows not needed every session
4. **Path-scoped rules solve context pollution** — load only when relevant files present
5. **Strong keywords matter more than position** — ALWAYS/NEVER/MUST signal regardless of line number

thoughts?

You’ve already done most of the hard thinking; this is a solid, well-structured design. A few targeted refinements will make it both more predictable and easier to evolve.
Big-picture assessment

    The separation you’re proposing (global CLAUDE.md → rules → skills → local overrides) matches what experienced users and Anthropic folks are converging on: small, specific, scoped files instead of a monolith.

    Your refactor plan explicitly addresses the two biggest real-world failure modes people report: (1) rules getting “lost in the middle” of long files, and (2) CLAUDE.md being treated as an enforcement layer instead of guidance.

    You’re already using path-scoped rules and skills in exactly the way practitioners describe: rules as always-loaded project memory, skills as zero-cost workflows you call on demand.

So directionally, you’re aligned with the emerging “meta” rather than fighting it.
Specific strengths of your plan

1. Clear hierarchy that matches how Claude actually behaves

Your written hierarchy (Managed → CLI → Local → Project → User) mirrors what the more detailed memory and rules writeups describe, even though different sources sometimes reorder labels. The critical bit is that you are thinking in terms of specificity, not just location:

    Global ~/CLAUDE.md = “who I am and how I like to work everywhere.”

    Project ./CLAUDE.md = “how to work in this repo.”

    Path-scoped .claude/rules/*.md = “what to do when working on these files.”

    Local CLAUDE.local.md = “what I want right now in this repo” (and gitignored).

That mental model is exactly how rule authors who care about predictability describe it.
2. You’re avoiding the monolithic CLAUDE.md trap

Experienced users and several blog posts make the same point: long CLAUDE.md files often hurt more than they help. Common guidance:

    Keep each CLAUDE.md under ~200 lines, preferably under 150.

    Only put things Claude cannot infer from the code, or that genuinely contradict default assumptions (non-obvious commands, weird architecture, nonstandard conventions).

Your plan to keep ~/CLAUDE.md to “critical-only” and shift the rest into rules and skills is exactly what those authors recommend.
3. Skills for repeated workflows: you’re using them “right”

Multiple practitioner guides say: if you type the same instructions three times, it should probably be a skill. You’re:

    Turning AWS account switching, Terraform flows, etc. into skills (aws-account-switch, terraform-review),

    Keeping the “always-loaded” part of SKILL.md small and linking out to reference docs, which matches skill authoring best practices.

That gives you the “just in time” behavior people aim for: rules codify defaults; skills encapsulate procedures you pull in on demand.
Where I’d tighten or slightly adjust

1. Make non-negotiables either hooks or very short rules

Several experienced writeups make a strong point: CLAUDE.md rules are requests; hooks are laws. For the things you truly care about (e.g., “never run destructive AWS commands without confirmation”):

    If it’s realistically enforceable, consider a Claude Code hook or a git/CI hook instead of (or in addition to) a rule.

    For safety-critical rules that must live in CLAUDE-land, keep them extremely short and consolidated in one small rules file (e.g., .claude/rules/safety-critical.md), and link that from global CLAUDE.md if needed.

That way, your “MUST/NEVER” safety rules are small enough that they’re never “lost in the middle,” and anything absolutely critical is also enforced by tooling rather than only by the model.
2. Be very deliberate about what stays in ~/CLAUDE.md

Authors who’ve iterated a lot on this recommend pruning global CLAUDE.md down to things that are truly global:

Good candidates to keep globally:

    How you want error reporting / uncertainty expressed (epistemic standards).

    Your basic communication style (brief vs verbose, markdown vs plaintext).

    Maybe a short note about your environment that every project should know (e.g., “I often have multiple AWS accounts; always confirm which one we’re in before destructive actions”).

Everything else — especially repo-specific or stack-specific behavior — is usually better as project rules or skills. You’re already moving in that direction; I’d just be ruthless about it.
3. Use failure-driven iteration and /insights

A recurring pattern from people who’ve stuck with Claude Code for months is: stop trying to design the perfect instruction hierarchy up front.

The loop they describe:

    Run with a minimal set of rules and your slimmed-down CLAUDE.md.

    When Claude does something wrong or annoying, promote the fix:

        If it’s project-specific, add a rules file or update one.

        If it’s cross-project, add it to global rules or global CLAUDE.md.

        If it’s a repeated workflow, turn it into a skill.

    Use /insights (or similar analysis commands) occasionally to surface friction patterns and then make structural changes based on those insights.

You already have a “Next Steps / Validate / Monitor” section; wiring this failure-driven loop into your normal working rhythm would give you a nice incremental improvement path.
4. Consider a small “meta-rules” block for rule persistence

One clever pattern some folks use to stop Claude from “forgetting” rules over long sessions is a self-referential meta-rules block that instructs Claude to restate key rules at the start of each response. For you, this would be most useful for the very small set of critical behaviors (interrupt protocol, AWS account confirmation).

A minimal, not-too-noisy version could live in global ~/CLAUDE.md or in a dedicated safety rules file:

xml
<behavioral_rules>
  <rule_1>MUST confirm active AWS account before destructive operations</rule_1>
  <rule_2>MUST summarize your plan before file modifications</rule_2>
  <rule_3>At the start of each response, restate any behavioral_rules that are relevant to the current action</rule_3>
</behavioral_rules>

That’s an experimental pattern (community, not official), but it directly targets the recency / context-rot problem you’re concerned about.
Minor implementation nits and nice-to-haves

    In your refactor plan, you have AWS rules both as global content and as path-scoped rules. I’d lean toward:

        Global: “Always confirm which AWS account we’re in before any destructive action.”

        Project/path scoped: concrete commands, flags, and guardrails for Terraform, CLI, etc.

    Consider a tiny ~/.claude/rules/preferences.md for strictly personal coding/communication prefs, separate from safety rules. That keeps “nice to have” behavior from diluting the critical stuff.

    Once you implement CLAUDE.local.md usage, it might be worth adding a one-line explanation at the top, e.g., “Temporary personal overrides for this repo; safe to delete at any time.” That keeps “future you” from wondering why behavior changed.

How I’d phase your plan

Given your current doc, I’d execute in this order when you have time:

    Shrink and reorder ~/CLAUDE.md

        Move only a small, curated set of non-negotiables to the end (epistemic standards, interrupt protocol, AWS confirmation).

        Strip or relocate anything project- or stack-specific.

    Stand up .claude/rules/ in your most active repo

        Start with 2–3 small files: aws-ops.md, git-protocols.md, maybe testing.md.

        Use path scoping aggressively so they only load when relevant.

    Create 1–2 high-value skills

        For the AWS account switch / Terraform flows you do all the time.

        Keep them small, test them, then iterate based on real usage.

    Wire in CLAUDE.local.md as your “scratchpad overrides”

        Use it when you’re doing unusual or risky work in a repo and don’t want to change team-wide rules.

    Adopt the failure-driven loop

        When Claude misbehaves, fix it by editing rules, skills, or CLAUDE.md — not just by chatting — so the improvement sticks.

From what you’ve written, you’re already thinking at this level of rigor; the tweaks above are mostly about pushing safety-critical behavior into “small + enforced” and making the evolution path explicit.
