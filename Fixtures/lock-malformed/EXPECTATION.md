# lock-malformed — expectation

Contents: `.agents/.skill-lock.json` is TRUNCATED, invalid JSON; one healthy
skill `survivor` sits alongside.

A correct scan MUST exit 0, report a `ledger-unreadable` issue naming the lock
path, treat the scope as having NO lock entries, and still inventory `survivor`
(ownership resolved from disk/frontmatter alone → ownerless, so a
`files-without-lock` finding is expected). A crash, non-zero exit, or dropped
placement is a fail.

(FIX-GARBAGE plants the same defect amid other garbage; this tree isolates it.)
