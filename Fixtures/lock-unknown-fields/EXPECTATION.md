# lock-unknown-fields — expectation

Contents: a SUPPORTED (v3) global lock whose `known-tool` entry carries extra
unknown keys (`channel: "beta"`, `priority: 7`) and whose top level carries
unknown keys (`futureTopLevelKey`, an `experimental` object).

A correct scan MUST exit 0, use the entry normally (ownership=vercel), and
surface the unknown keys with their ORIGINAL values in the report's
entry/top-level extras — never drop them, never error on them.
