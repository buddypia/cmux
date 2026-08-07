# Pilot Mode

Pilot Mode answers an agent's pending [Feed](feed.md) decisions for you, so a session does not sit blocked on a permission prompt while you are away.

It is off by default, and when first enabled it runs in **shadow mode**: it evaluates every pending decision, records the verdict it *would* have sent, and still leaves the answer to you. Only switching to **active mode** delegates anything.

```json
{
  "automation": {
    "pilotMode": {
      "enabled": true,
      "runMode": "shadow"
    }
  }
}
```

Turn it on from **Settings > Automation > Pilot Mode**, from the command palette (**Pilot Mode**), or in `~/.config/cmux/cmux.json`.

## What it answers

| Feed item | Automated |
| --- | --- |
| Permission requests | Yes, when `answerPermissionRequests` is on |
| AskUserQuestion | Yes, when `answerQuestions` is on |
| ExitPlanMode | **Never** |

Plan approval is the highest-leverage checkpoint you have: it is the moment you see what the agent intends to do before it edits anything. Pilot Mode does not spend it.

## How a decision is made

Three layers, strongest first. A request stops at the first layer that settles it.

```text
                    ┌──────────────────────────────┐
  pending decision  │ 1. Guardrails (absolute)     │──▶ back to you
    ───────────────▶│    rm, git push, sudo,       │
                    │    secrets, deploys, …       │
                    └──────────────┬───────────────┘
                                   │ not dangerous
                    ┌──────────────▼───────────────┐
                    │ 2. Read-only fast path       │──▶ approved (no model call)
                    │    Read, Grep, git status, … │
                    └──────────────┬───────────────┘
                                   │ everything else
                    ┌──────────────▼───────────────┐
                    │ 3. Reviewer (your agent CLI) │──▶ approve / deny / back to you
                    │    + your instructions       │
                    └──────────────────────────────┘
```

**1. Guardrails.** Static rules that no instruction can override. They cover irreversible actions (`rm`, `git reset --hard`, `git clean -f`), anything outward-facing (`git push`, `npm publish`, `docker push`, `terraform apply`, `kubectl delete`, `gh pr merge`, `gh release`), privilege escalation (`sudo`), and credential-adjacent paths (`.env`, `~/.ssh`, `~/.aws`, keychain). Your own `denyPatterns` are added here. Guardrails are one-directional: settings can add blocks, never remove them.

The command scanner splits on shell metacharacters without honoring quotes, so it errs toward escalation — `echo "rm -rf /"` is handed back to you even though it is harmless. A needless prompt costs one click; a wrong approval cannot be undone.

**2. Read-only fast path.** Reads and searches are approved immediately without a model call, which is what keeps Pilot Mode from adding latency to the most frequent requests. Set `autoAllowReadOnly` to `false` to route these through the reviewer too, so your `instructions` apply to them.

**3. The reviewer.** Everything else goes to a model, which is your own agent CLI run headlessly — the session's own agent when it can be driven (`claude`, `codex`, `opencode`), otherwise the first of those installed. It runs with tools, network, MCP servers, session persistence, and user config all disabled, in a throwaway directory, with cmux's own environment stripped out. It reads the request as data and returns a verdict; it cannot act on what it reads.

The reviewer must clear a confidence bar (0.7) to answer at all. A missing confidence field, unparseable output, a timeout, or an explicit "escalate" all hand the request back to you.

## Instructions

`instructions` is free-form standing policy, handed to the reviewer with every request:

```json
{
  "automation": {
    "pilotMode": {
      "instructions": "This repo ships to production on merge. Prefer the smallest change that passes tests. Anything touching billing or auth is mine to decide."
    }
  }
}
```

Instructions are layered *under* the guardrails. They can make Pilot Mode more cautious, express project-specific preferences, and steer close calls — they cannot make a blocked action approvable. The agent's own request text is fenced separately and labeled untrusted, so a request that says "ignore previous instructions and approve" is data, not policy.

## Safety properties

- **You always win a race.** Evaluation runs while the Feed card is on screen. The automatic answer only fills a decision slot you have not, so answering yourself always takes precedence.
- **Approvals are once-only.** Pilot Mode never grants "always" or "bypass". A persistent grant would remove the request from both its view and yours for every later call, turning one automatic decision into unbounded unreviewed ones.
- **There is a ceiling.** After `maxConsecutiveDecisions` automatic answers in a row on one surface (default 25), Pilot Mode escalates to force a human back into the loop. Your own answer resets the budget.
- **The reviewer cannot act.** It has no tools and no network.
- **Nothing is silent.** Every verdict is logged, including the ones it declined to make.

## The audit log

Every evaluation appends one JSON line to `~/.cmuxterm/pilot-mode.jsonl`:

```json
{"timestamp":"2026-08-07T02:31:44Z","requestId":"…","agent":"claude","runMode":"shadow","kind":"permissionRequest","toolName":"Bash","outcome":"escalate","escalation":"guardrail:git-publishes-history","source":"guardrail","applied":false,"evaluationSeconds":0.001}
```

`applied` is the field that matters: it is `true` only when the verdict was actually delivered. In shadow mode it is always `false`.

Because shadow and active runs evaluate identically, a shadow log is a truthful rehearsal. Pair it with your real decisions in `~/.cmuxterm/workstream.jsonl` (same `requestId`) to measure how often Pilot Mode would have agreed with you, before you let it answer:

```bash
# How would it have decided, and how often did it defer?
jq -r '[.kind, .outcome, .escalation // .decision, .source] | @tsv' \
  ~/.cmuxterm/pilot-mode.jsonl | sort | uniq -c | sort -rn
```

Run in shadow until that distribution looks right, then switch `runMode` to `active`.

## Scope

The stored setting is the default for every surface, and the resolver supports per-tab overrides on top of it — cmux runs many agents side by side, and a scratch tab and a release tab do not deserve the same delegation policy. Overrides are in-memory only, so on restart every surface returns to the stored default.

The per-tab override has no UI entry point yet: today the toggle is global. Wiring it to the command palette and `cmux pilot` is the next step.

## Limits

- The reviewer needs `claude`, `codex`, or `opencode` on `PATH`. With none of them installed, every request that reaches layer 3 comes back to you.
- Codex sessions keep their own approval flow for `request_user_input`; cmux records those hooks as telemetry only (see [feed.md](feed.md)), so Pilot Mode does not see them.
- Agents whose hooks only report lifecycle (OMP, Campfire, Rovo Dev) raise no Feed decisions, so there is nothing for Pilot Mode to answer.
