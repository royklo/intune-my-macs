---
authority: canonical
applies-to: intune-my-macs/
last-reviewed: 2026-06-25
owners:
  - alias: theneiljohnson
    role: docs
  - alias: CKunze-MSFT
    role: docs
review-cadence: quarterly
audience: agent
---

<!-- Copyright (c) Microsoft Corporation. -->
<!-- Licensed under the MIT License. -->

# Testing & validation patterns

This repository deploys **declarative configuration and shell scripts**, not a
compiled application, so "testing" here means **validating that every artifact is
well-formed and internally consistent**, then exercising the engine in **dry-run**
mode. There is no unit-test framework; follow the patterns below when adding or
changing an artifact.

## 1. The fast local loop — `tools/verify.sh`

Run it before every push:

```bash
./tools/verify.sh
```

It validates, repo-wide:

- **JSON** policies parse (UTF-8 BOM tolerated, as in Intune/Graph exports).
- **XML** manifests are well-formed (`xmllint`).
- **`.mobileconfig`** profiles are valid property lists (`plutil -lint`).
- **PowerShell** scripts parse (via the PowerShell language parser).
- **Shell** scripts pass `shellcheck` (advisory — warnings do not fail the run).

Hard failures (malformed JSON/XML/mobileconfig or a PowerShell parse error) exit
non-zero; fix them before pushing.

## 2. Manifest & settings consistency (the release checklist)

[`tools/verify.sh`](../tools/verify.sh) covers well-formedness; the deeper,
semantic checks live in the release flow
([../.github/prompts/ship.prompt.md](../.github/prompts/ship.prompt.md)). When you
add or change an artifact, confirm:

- **Sibling manifest exists.** Every `.json` / `.mobileconfig` / script / `.pkg`
  has a sibling `*.xml` `<MacIntuneManifest>`.
- **`<ReferenceId>` is unique** across the repo and follows
  `TYPE-CATEGORY-NUMBER` (see
  [../standards/policy-naming-standard.prd](../standards/policy-naming-standard.prd)).
- **`<SourceFile>` resolves** to the real file, and `<SettingsCount>` is
  plausible.
- **Settings Catalog `settings[]` IDs are contiguous and 0-based** (`"0"`, `"1"`,
  `"2"`, …) — gaps or a non-zero start break import.

A quick uniqueness check:

```bash
grep -rho '<ReferenceId>[^<]*</ReferenceId>' macOS | sort | uniq -d
# (no output = all reference IDs are unique)
```

## 3. Integration check — dry-run the engine

The engine defaults to **dry-run**, which is the safe integration test: it
discovers manifests, resolves placeholders, and logs the intended Graph calls
**without writing anything**.

```bash
# Preview macOS deployment (nothing is created):
pwsh ./mainScript.ps1 --assign-group "Intune Mac Pilot"

# Narrow to one artifact while iterating:
pwsh ./mainScript.ps1 --names "POL-SEC-001"
```

Only add `--apply` against a disposable **evaluation** tenant — never as part of
routine validation.

## 4. Regenerate generated docs

If you changed an artifact under `macOS/`, regenerate the catalog and confirm the
diff reflects only your change:

```bash
python3 tools/Generate-ConfigurationDocumentation.py
git --no-pager diff --stat -- INTUNE-MY-MACS-DOCUMENTATION.md
```

Never hand-edit `INTUNE-MY-MACS-DOCUMENTATION.md`.

## Adding a new artifact — checklist

1. Create the artifact under the correct `macOS/<area>/` folder, named after its
   reference ID.
2. Add the sibling `.xml` manifest with a unique `<ReferenceId>`, correct
   `<SourceFile>`, and `<SettingsCount>`.
3. Add the Microsoft copyright header to any new script.
4. `./tools/verify.sh` → must pass.
5. Dry-run `mainScript.ps1` and confirm the new object appears as intended.
6. Regenerate documentation; update `CHANGELOG.md`.
