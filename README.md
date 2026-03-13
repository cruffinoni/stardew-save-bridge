# Stardew Save Bridge

Stardew Save Bridge is a Windows-first PowerShell utility for safely moving a Stardew Valley save between a PC and an Android phone. It is a controlled handoff tool: inspect both sides, choose the version to keep, back up the overwritten side, copy, verify, and log the result.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7 on Windows
- `adb` installed and available in `PATH`, or configured through `config/user.json`
- USB debugging enabled on the Android phone
- A Stardew Valley save under `%APPDATA%\StardewValley\Saves`

## Setup

### Enable USB debugging

1. On the phone, enable Developer options.
2. Turn on USB debugging.
3. Connect the phone over USB and approve the debugging prompt when it appears.

### Ensure `adb` is available

1. Install Android platform tools.
2. Confirm `adb version` works in PowerShell.
3. If needed, set `adbPath` in `config/user.json`.

### Configure the tool

The first run creates `config/user.json` from `config/default.json`. Update it if you need a custom Android save root, backup location, staging path, preferred device, or UI mode.

## First-run workflow

1. Connect the phone and confirm `adb devices` shows it as `device`.
2. Run `.\stardew-save-bridge.ps1`.
3. Choose `Inspect saves`.
4. Review the comparison, version hints, and recommendation.
5. Choose `Use PC save`, `Use Phone save`, or `Restore backup` only after reviewing the confirmation prompt.

## Example commands

```powershell
.\stardew-save-bridge.ps1
.\stardew-save-bridge.ps1 -Action Inspect -SaveSlot "Farm_123456789" -NonInteractive -DeviceId "emulator-5554"
.\stardew-save-bridge.ps1 -Action UsePC -SaveSlot "Farm_123456789" -DeviceId "emulator-5554" -Force
.\stardew-save-bridge.ps1 -Action UsePhone -SaveSlot "Farm_123456789" -DeviceId "emulator-5554" -DryRun
.\stardew-save-bridge.ps1 -Action RestoreBackup -SaveSlot "Farm_123456789" -BackupId "20260313-200000" -RestoreTarget PC -Force
```

## Makefile shortcuts

If you use GNU Make, the repo now includes a simple `Makefile`:

```bash
make help
make inspect NONINTERACTIVE=1
make use-pc SLOT=Farm_123 DEVICE=R52X90E13PP FORCE=1
make run ARGS="-Action Inspect -NonInteractive"
make test
```

On WSL, `make` uses the Windows PowerShell executable directly. On Windows PowerShell or Command Prompt, `make` uses `powershell.exe` by default. Override `PS_EXE` if you want a different runtime.
On WSL, the Makefile syncs the repo into your Windows Desktop copy first so Windows PowerShell runs a normal Windows path instead of a `\\wsl.localhost\...` path.
`make test` requires Pester 5+. If it is missing, the target prints the exact `Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck` command to run.

## Double-click on Windows

If you want to launch the tool by double-clicking:

1. Copy the whole project folder to a normal Windows path such as `C:\Users\<you>\Desktop\stardew-save-bridge`.
2. Do not run it from `\\wsl.localhost\...`; PowerShell treats that as a remote path and may block unsigned scripts.
3. Double-click `Run-StardewSaveBridge.cmd`.

The launcher starts `stardew-save-bridge.ps1` with `powershell.exe` and keeps the window open at the end so you can read the output.
If you run the `.ps1` directly, Windows execution policy may still block it depending on your machine policy.

## Restore workflow

1. Choose `Restore backup`.
2. Pick the save slot.
3. Pick the backup timestamp.
4. Choose `Restore to PC` or `Restore to Phone`.
5. Confirm the restore after reviewing the warning.
6. Review the verification result in the console and logs.

## Testing

Use Pester from Windows PowerShell or PowerShell 7:

```powershell
Invoke-Pester -Path .\tests
```

The fixtures in `fixtures/` are synthetic and safe to distribute.

## Troubleshooting

### Unauthorized device

- Unlock the phone.
- Reconnect USB.
- Accept the USB debugging prompt.
- Re-run `adb devices` and confirm the state is `device`, not `unauthorized`.

### No device found

- Confirm the cable supports data transfer.
- Re-run `adb devices`.
- Check that USB debugging is enabled.
- Set `adbPath` if `adb` is not on `PATH`.

### Multiple devices connected

- Pass `-DeviceId <id>`, or set `preferredDeviceId` in `config/user.json`.
- Disconnect unused devices if you want the interactive prompt to stay simpler.

### Android save path inaccessible

- Confirm the save root in `config/user.json`.
- The default shell path is `/sdcard/Android/data/com.chucklefish.stardewvalley/files/Saves`.
- Check that the installed package is `com.chucklefish.stardewvalley`.
- Reconnect the device and retry `Inspect saves`.

### Version mismatch detected

- Review the reported save version and target game version.
- Update the older game first, or use `-Force` only if you accept the risk of an unreadable save.

### Verification failure

- Do not open the save immediately.
- Re-run `Inspect saves`.
- Restore the backup created before the overwrite if the copied files do not match.
