# Security

Claude Island touches sensitive things — your Claude Code credential, your
prompt contents, and (optionally) the permission dialogs that gate what Claude
may do. This page says exactly what it does with them, what an attacker could
and couldn't gain, and what to check before enabling each feature. It was
shaped in part by an independent review in the first hours after release;
that kind of scrutiny is welcome — see [Reporting](#reporting).

## What the app touches

**Reads:** the Claude Code session registry (`~/.claude/sessions/`),
transcripts (`~/.claude/projects/**/*.jsonl`), skills/agents/hooks configs,
and — only after you press Connect — the `Claude Code-credentials` keychain
item.

**Writes:** its own directory `~/.claude/island/` (owner-only, `0700`), and
`~/.claude/settings.json` only when you enable a hook toggle (with a backup
to `~/.claude/island/settings-backup.json` first, and a hard refusal to touch
a settings file that doesn't parse).

**Network:** one `GET https://api.anthropic.com/api/oauth/usage`,
authenticated with your own token, cached for 60 seconds. There is no other
network access of any kind — no telemetry, no update checks, no third-party
hosts, no dependencies.

## The two hook toggles

The Claude Code integration is split so the read-only half and the
answer-capable half are separate decisions:

1. **Session insights** (read-only) — installs `capture.sh` (appends hook
   events to `~/.claude/island/events/<session>.jsonl`) and `statusline.sh`
   (saves Claude Code's own context accounting). This is what powers the
   Context page and exact-prompt display. It never emits a hook decision;
   it only records.
2. **Click-to-answer** (write) — additionally installs `answer.sh`/
   `answer.py`, a blocking `PermissionRequest` hook that races the terminal
   dialog and emits an allow/deny decision **only** when it finds an answer
   file the island wrote because you clicked an option.

The statusline capture claims the `statusLine` slot in settings.json only if
you have none configured. If you later set your own, the capture yields the
slot and the Context page goes blank — that's the documented trade, not a
malfunction.

## Threat model for click-to-answer

`answer.py` is not an auto-approver. It blocks for up to 290 seconds and
emits a decision only for an answer file that matches the live prompt on
every axis: the per-turn `prompt_id` nonce, the `tool_name`, prefixes of the
prompt's actual input values, and file freshness. Anything mismatched is
left untouched for the racer that owns it; anything unparseable is discarded;
the scripts execute nothing from the payloads they read. No click means no
decision — the terminal dialog stands.

Three trade-offs you accept by enabling it:

1. **Approval moves off the terminal.** Claude Code's permission prompt is an
   out-of-band human check per sensitive action; this lets a GUI click
   satisfy it. The check is still human — but the surface changes.
2. **A local same-user process could forge an answer.** The identifying
   fields the answerer verifies are readable from the events log by any
   process running as you, so local malware could approve a prompt that is
   currently on screen. This is a narrow, local-only escalation: the same
   malware could already edit `~/.claude/settings.json`, install its own
   hooks, or drive your terminal directly. Claude Island doesn't create that
   attacker; it adds one more thing such an attacker could do.
3. **"Don't ask again" persists rules.** The island's allow-always option
   writes the same permanent permission rules the terminal's equivalent
   button writes (Claude Code's own suggested rules, echoed verbatim).

## Data at rest

Captured events include dialog-time tool inputs — commands, file paths,
question text — in plaintext, the same content that already exists in your
`~/.claude` transcripts. Mitigations: `~/.claude/island/` and everything in
it is owner-only (`0700` directories, `umask 077` writers), event files are
pruned after seven days, and disabling the toggles deletes the scripts and
hook entries cleanly.

## On managed and enterprise seats

If your organization manages permission policies, it may do so precisely so
that a human reviews each sensitive tool call in the terminal. A GUI that can
satisfy those prompts may run against that intent or your acceptable-use
policy. Check before enabling click-to-answer — and note that the usage
meter, session status, and even Session insights work fully without it.

## Reporting

Please report suspected vulnerabilities privately via GitHub's security
advisories on this repository (Security → Report a vulnerability) rather
than public issues. Honest, adversarial review is how half of this page came
to exist.
