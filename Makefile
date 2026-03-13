ifeq ($(OS),Windows_NT)
SHELL := cmd.exe
PS_EXE ?= powershell.exe
SCRIPT_PATH := $(CURDIR)\stardew-save-bridge.ps1
TEST_PATH := $(CURDIR)\tests
TEST_RUNNER := $(CURDIR)\tests\Run-Tests.ps1
SYNC_CMD :=
else
PS_EXE ?= /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
WIN_PROFILE_WIN := $(shell cd / && '/mnt/c/Windows/System32/cmd.exe' /C echo %USERPROFILE% 2>/dev/null | tail -n 1 | tr -d '\r')
WIN_PROFILE_WSL := $(shell wslpath "$(WIN_PROFILE_WIN)")
WIN_REPO_WIN ?= $(WIN_PROFILE_WIN)\Desktop\stardew-save-bridge
WIN_REPO_WSL ?= $(WIN_PROFILE_WSL)/Desktop/stardew-save-bridge
SCRIPT_PATH := $(WIN_REPO_WIN)\stardew-save-bridge.ps1
TEST_PATH := $(WIN_REPO_WIN)\tests
TEST_RUNNER := $(WIN_REPO_WIN)\tests\Run-Tests.ps1
SYNC_CMD := mkdir -p "$(WIN_REPO_WSL)" && rsync -a --exclude '.git/' --exclude 'config/user.json' --exclude 'logs/' --exclude 'backups/' --exclude 'staging/' ./ "$(WIN_REPO_WSL)/" &&
endif

SCRIPT_FLAGS :=

ifneq ($(strip $(SLOT)),)
SCRIPT_FLAGS += -SaveSlot "$(SLOT)"
endif

ifneq ($(strip $(DEVICE)),)
SCRIPT_FLAGS += -DeviceId "$(DEVICE)"
endif

ifneq ($(strip $(BACKUP_ID)),)
SCRIPT_FLAGS += -BackupId "$(BACKUP_ID)"
endif

ifneq ($(strip $(RESTORE_TARGET)),)
SCRIPT_FLAGS += -RestoreTarget "$(RESTORE_TARGET)"
endif

ifneq ($(strip $(CONFIG)),)
SCRIPT_FLAGS += -ConfigPath "$(CONFIG)"
endif

ifeq ($(FORCE),1)
SCRIPT_FLAGS += -Force
endif

ifeq ($(DRY_RUN),1)
SCRIPT_FLAGS += -DryRun
endif

ifeq ($(NONINTERACTIVE),1)
SCRIPT_FLAGS += -NonInteractive
endif

.PHONY: help run inspect use-pc use-phone restore test

help:
	@echo Available targets:
	@echo   make run ARGS="-Action Inspect -NonInteractive"
	@echo   make inspect NONINTERACTIVE=1
	@echo   make use-pc SLOT=Farm_123 DEVICE=R52X90E13PP FORCE=1
	@echo   make use-phone SLOT=Farm_123 DEVICE=R52X90E13PP DRY_RUN=1
	@echo   make restore SLOT=Farm_123 BACKUP_ID=20260313-200000 RESTORE_TARGET=PC FORCE=1
	@echo   make test
	@echo Variables:
	@echo   ARGS, SLOT, DEVICE, BACKUP_ID, RESTORE_TARGET, CONFIG
	@echo   FORCE=1, DRY_RUN=1, NONINTERACTIVE=1
	@echo   PS_EXE=... to override the PowerShell executable

run:
	$(SYNC_CMD) "$(PS_EXE)" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$(SCRIPT_PATH)" $(ARGS)

inspect:
	$(SYNC_CMD) "$(PS_EXE)" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$(SCRIPT_PATH)" -Action Inspect $(SCRIPT_FLAGS) $(ARGS)

use-pc:
	$(SYNC_CMD) "$(PS_EXE)" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$(SCRIPT_PATH)" -Action UsePC $(SCRIPT_FLAGS) $(ARGS)

use-phone:
	$(SYNC_CMD) "$(PS_EXE)" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$(SCRIPT_PATH)" -Action UsePhone $(SCRIPT_FLAGS) $(ARGS)

restore:
	$(SYNC_CMD) "$(PS_EXE)" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$(SCRIPT_PATH)" -Action RestoreBackup $(SCRIPT_FLAGS) $(ARGS)

test:
	$(SYNC_CMD) "$(PS_EXE)" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$(TEST_RUNNER)"
