<!-- Copyright (c) Microsoft Corporation. -->
<!-- Licensed under the MIT License. -->

## Summary

<!-- What does this change do, and why? Link any related issue (#123). -->

## Type of change

- [ ] New or changed Intune artifact (policy / config / script / app / custom attribute)
- [ ] Engine or tooling change (`mainScript.ps1`, `Start-IntuneMyMacs.ps1`, `tools/`)
- [ ] Documentation / agent context
- [ ] Other (describe):

## Validation

- [ ] `pwsh ./scripts/verify.ps1` passes.
- [ ] Any new/changed artifact has a sibling `.xml` manifest with a **unique** `<ReferenceId>` and a `<SourceFile>` that resolves.
- [ ] Settings Catalog `settings[]` IDs are contiguous and 0-based.
- [ ] Dry-ran `mainScript.ps1` and the result looks correct (`pwsh ./mainScript.ps1 …`, no `--apply`).
- [ ] Regenerated `INTUNE-MY-MACS-DOCUMENTATION.md` if artifacts changed (`python3 tools/Generate-ConfigurationDocumentation.py`).
- [ ] Added the Microsoft copyright header to new first-party files; preserved any third-party notice.
- [ ] Updated `CHANGELOG.md` (newest first), linking changed file paths.

## Notes

<!-- Anything reviewers should know: trade-offs, follow-ups, screenshots. -->
