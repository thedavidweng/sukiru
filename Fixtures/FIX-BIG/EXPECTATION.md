# FIX-BIG — expectation

Contents: 40 vercel-owned user-scope skills `skill-000`..`skill-039`, each with a
global lock entry.

A correct scan MUST exit 0 and inventory all 40 skills (ownership=vercel,
single placement each), producing zero actionable findings. Used for launch
non-blocking, scrolling, and output-size checks; the count (40) is fixed so
validators can assert it.
