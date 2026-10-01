## Summary

<!-- What does this change and why? Link related issues. -->

## Checklist

- [ ] Commit messages follow Conventional Commits.
- [ ] `swiftlint lint --strict`, `swift format lint --strict --recursive Sources Tests App`, and `swift test` pass.
- [ ] Tests cover the behavior change.
- [ ] No installer ledger writes outside the official CLIs (ADR-0001).
- [ ] UI changes follow the ADR-0006 checklist, strings are translated (`Scripts/sync-strings.sh`), and screenshots are attached.
- [ ] Documentation is updated.
