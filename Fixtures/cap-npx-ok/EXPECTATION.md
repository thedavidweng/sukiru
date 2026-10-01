# cap-npx-ok — expectation

Contents: `bin/npx` — a stub answering the capability probe
(`npx -y skills@latest --version`) with `1.5.26`. No gh stub here (compose
with `cap-gh-ok`).

Use: `PATH="<this>/bin[:<cap-gh-ok>/bin]:/usr/bin:/bin" sukiru-cli capabilities --format json`.

A correct capabilities report MUST exit 0 and report npx resolvable=true,
skillsVersion="1.5.26".
