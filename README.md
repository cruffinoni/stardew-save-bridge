# Stardew Save Bridge

Stardew Save Bridge is a Windows-first PowerShell utility for safely moving a Stardew Valley save between a PC and an Android phone. It is a controlled handoff tool: inspect both sides, choose the version to keep, back up the overwritten side, copy, verify, and log the result.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7 on Windows
- `adb` installed and available in `PATH`, or configured through `config/user.json`
- USB debugging enabled on the Android phone
- Wireless debugging paired if you want mDNS-based discovery to find the device over the network
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

The first run creates `config/user.json` from `config/default.json`. Update it if you need a custom Android save root, backup location, staging path, preferred device, UI mode, wireless daemon settings, or a fixed PC game executable path.

`pcGameExePath` is optional. When it is blank, the tool tries to auto-detect `Stardew Valley.exe` from common Steam and GOG install locations on Windows. The first successful detection is saved back to `config/user.json`. If you move the game later, update `pcGameExePath` to the new executable path.

For the daemon, `daemonIntervalMinutes` is the active setting. The wireless host/port settings are kept for compatibility with older setups:

- `wirelessDeviceHost`: legacy wireless endpoint setting
- `wirelessDevicePort`: legacy wireless endpoint setting
- `daemonIntervalMinutes`: how often the daemon checks for changes; default is `30`

## First-run workflow

1. Pair wireless debugging if you want network discovery, or connect the phone over USB.
2. Confirm `adb devices` shows the device as `device` for USB fallback.
3. Run `.\stardew-save-bridge.ps1`.
4. Choose `Inspect saves`.
5. Review the visible `Selected device:` message, comparison, version hints, and recommendation.
6. Choose `Use PC save`, `Use Phone save`, or `Restore backup` only after reviewing the confirmation prompt.

## Example commands

```powershell
.\stardew-save-bridge.ps1
.\stardew-save-bridge.ps1 -Action Inspect -SaveSlot "Farm_123456789" -NonInteractive -DeviceId "emulator-5554"
.\stardew-save-bridge.ps1 -Action UsePC -SaveSlot "Farm_123456789" -DeviceId "emulator-5554" -Force
.\stardew-save-bridge.ps1 -Action UsePhone -SaveSlot "Farm_123456789" -DeviceId "emulator-5554" -DryRun
.\stardew-save-bridge.ps1 -Action RestoreBackup -SaveSlot "Farm_123456789" -BackupId "20260313-200000" -RestoreTarget PC -Force
.\stardew-save-bridge.ps1 -Action Daemon -NonInteractive
```

## Continuous Sync Daemon

The daemon uses the same mDNS-first discovery flow as the interactive workflows to keep PC and phone/tablet saves synchronized in the background.

Behavior:

- It queries `adb mdns services` first and auto-selects the first usable mDNS device.
- It falls back to USB device discovery when no usable mDNS device is available.
- It prints the selected device in the console at the start of each cycle.
- It checks every discovered save slot and syncs only when one side is clearly newer.
- It backs up the side that will be overwritten before copying.
- It skips the cycle if no usable mDNS or USB device is available.
- It skips the cycle if Stardew Valley is running on the PC.
- It writes a normal run log for each daemon cycle under `logs/`.

Start it with:

```powershell
.\stardew-save-bridge.ps1 -Action Daemon -NonInteractive
```

Recommended setup:

1. Pair wireless `adb` with the phone/tablet first.
2. Confirm `adb mdns services` lists the device if you expect network discovery to be used.
3. Leave USB debugging enabled if you want the daemon to have a wired fallback.
4. Start the daemon from Windows PowerShell or PowerShell 7.

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

- Re-run `adb mdns services` to check whether the device is discoverable over wireless debugging.
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
