# multi-host-inventory — expectation

Contents (placement manifest — five distinct skills, one placement each):
- user scope: `.home/.agents/skills/canon-tool` (canonical store),
  `.home/.claude/skills/claude-tool` (claude-code host, detected via
  config.json), `.home/.codex/skills/codex-tool` (codex host, detected via
  config.json);
- project scope (`proj/`): `.agents/skills/proj-canon` (canonical),
  `.claude/skills/proj-claude` (claude-code project dir).

Scan with SUKIRU_HOME=<this>/.home, SUKIRU_ROOTS=<this>/proj.

A correct scan MUST exit 0 and report EXACTLY these five placements — no
missing, no extra — each with correct workspace attribution, placement kind
(directory), and the skill name parsed from SKILL.md. All five are ownerless,
so `files-without-lock` findings are expected; they do not affect the
placement-set assertion.
