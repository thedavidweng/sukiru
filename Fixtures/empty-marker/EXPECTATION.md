# empty-marker — expectation

Contents: a HOME with unrelated content (`notes.txt`, `Projects/`) but NO
`~/.claude`, `~/.codex`, or `~/.vibe`, and no `CLAUDE_CONFIG_DIR` /
`CODEX_HOME` / `VIBE_HOME` in the environment.

A correct scan MUST (VAL-SCAN-014): report the empty-detection-marker hosts
(claude-code, codex, mistral-vibe) as ABSENT — their detection probes the
resolved config base itself and must never fall through to a merely
non-empty `$HOME`. The workspace list contains no entry for any of them.
