# leftover-spray — expectation

Contents: a HOME emulating official-CLI spray. `~/.qoder/` contains ONLY a
`skills/` entry (CLI residue: qoder was never installed); `~/.claude/`
contains `skills/` plus a real `config.json` (a genuine claude-code install);
no `~/.cursor` at all (an absent host).

A correct scan MUST (VAL-SCAN-012):
- emit a `host:qoder` workspace with `installed: false` while STILL scanning
  its skills root (the `sprayed` placement appears in the inventory);
- emit a `host:claude-code` workspace with `installed: true`;
- omit the absent host (cursor) entirely — no workspace entry for it.
