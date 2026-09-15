# FIX-EMPTY — expectation

Contents: an otherwise-empty fake HOME (only this note). No skill directories,
no host config dirs, no lock files anywhere.

A correct scan (SUKIRU_HOME=<this dir>, default scope) MUST:
- exit 0 with valid JSON;
- report zero workspaces that contain content, zero placements (skills == []);
- report zero findings and zero issues.
