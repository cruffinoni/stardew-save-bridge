# Repository Guidelines

## Project Structure & Module Organization

The root entrypoint is `stardew-save-bridge.ps1`. Core behavior is split across `src/` modules:

- `StardewSaveBridge.Core.psm1`: config, paths, logging, shared helpers
- `StardewSaveBridge.Save.psm1`: save discovery, validation, hashing, version parsing
- `StardewSaveBridge.Adb.psm1`: `adb` device and file operations
- `StardewSaveBridge.Backup.psm1`: backup creation and retention
- `StardewSaveBridge.Workflow.psm1`: interactive and CLI workflows

Tests live in `tests/`. Synthetic save fixtures belong in `fixtures/`. Default configuration is in `config/default.json`; local overrides are written to `config/user.json`. Runtime logs go to `logs/`.

## Build, Test, and Development Commands

Run locally from Windows PowerShell:

```powershell
.\stardew-save-bridge.ps1
.\stardew-save-bridge.ps1 -Action Inspect -NonInteractive
Invoke-Pester -Path .\tests
.\tests\Run-Tests.ps1
```

GNU Make is also supported through the root `Makefile`:

```bash
make help
make inspect NONINTERACTIVE=1
make use-phone SLOT=Farm_123 DEVICE=R52X90E13PP DRY_RUN=1
make test
```

From WSL, the Makefile syncs the repo into the Windows Desktop copy and runs that Windows-local copy with `powershell.exe`. This avoids UNC-path execution issues.
The `make test` target requires Pester 5+ and prints an install command if only the inbox Windows Pester 3.x module is available.

Use `Run-StardewSaveBridge.cmd` for double-click testing on Windows. When editing from WSL, sync changes to the Windows copy before testing there.
From WSL, you can also invoke the Windows runtimes directly for real validation:

```bash
/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -ExecutionPolicy Bypass -File C:\Users\<you>\Desktop\stardew-save-bridge\stardew-save-bridge.ps1 -Action Inspect -NonInteractive
"/mnt/c/Program Files/PowerShell/7/pwsh.exe" -ExecutionPolicy Bypass -File C:\Users\<you>\Desktop\stardew-save-bridge\stardew-save-bridge.ps1 -Action Inspect -NonInteractive
```

## Coding Style & Naming Conventions

Use 4-space indentation and PowerShell’s standard verb-noun function naming. Keep functions small and side effects isolated. Prefer explicit parameters, ordered hashtables for structured output, and `SHA256` hashing where comparison logic is involved. Centralize user-facing copy rather than scattering strings through workflows.

Module files should be named `StardewSaveBridge.<Area>.psm1`. Tests should mirror behavior areas, for example `Save.Tests.ps1` or `Workflow.Tests.ps1`.

## Testing Guidelines

Pester is the required test framework. Add or update tests for every behavior change, especially around save safety, `adb` mocking, backup retention, and user-facing terminology. Keep fixtures synthetic and safe to distribute.

Name tests by behavior, not implementation detail. Example: `It 'does not concatenate the slot name when exactly one slot exists on both sides'`.

## Commit & Pull Request Guidelines

This repository has no established commit history yet. Use short, imperative commit subjects such as `Fix inspect recommendation for identical saves`. Keep unrelated changes out of the same commit.

PRs should include:

- a brief summary of the user-visible change
- test evidence (`Invoke-Pester` output or manual PowerShell runs)
- notes on Windows vs. WSL validation
- screenshots or console output when changing interactive UX

## Security & Configuration Tips

Do not commit personal `config/user.json`, device IDs, or real save data. Treat `fixtures/` as synthetic-only. Validate before overwrite, and preserve the PRD progress log in `PRD.txt` when milestone work changes state.
