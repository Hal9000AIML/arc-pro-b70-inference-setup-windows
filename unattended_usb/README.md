# Unattended Windows Install USB — Work in Progress

This folder is the planned bootable-USB equivalent of the Ubuntu repo's
`build_iso.sh`. It is **not yet functional** — Windows has no `cloud-init`
equivalent, so building one requires:

## Required pieces

1. **Windows 11 ISO** from <https://www.microsoft.com/software-download/windows11>
2. **Windows ADK** + **Windows PE add-on** from <https://learn.microsoft.com/windows-hardware/get-started/adk-install>
3. **`autounattend.xml`** at the root of the USB. Generated with Windows
   System Image Manager (WSIM) from the ADK. Must specify:
   - Edition (Pro / Pro for Workstations recommended for Hyper-V/WSL2)
   - Disk wipe + partition layout (or `<DiskConfiguration>` set to interactive)
   - Local user account (`user` / `changeme` to match the Ubuntu installer)
   - `<FirstLogonCommands>` calling `C:\ProB70\bootstrap.cmd`
4. **`bootstrap.cmd`** copied to the install via `<RunSynchronousCommand>`:
   ```batch
   @echo off
   powershell -ExecutionPolicy Bypass -Command "iwr -useb https://raw.githubusercontent.com/Hal9000AIML/arc-pro-b70-inference-setup-windows/main/install.ps1 -OutFile C:\ProB70\install.ps1; C:\ProB70\install.ps1"
   ```
5. **`build_usb.ps1`** — wraps the above: mounts the Win11 ISO, copies the
   contents to the USB, drops `autounattend.xml` + `bootstrap.cmd` at the root,
   makes it bootable with `bootsect.exe /nt60`.

## Status

| Piece | Status |
|---|---|
| `autounattend.xml` template | TODO |
| `bootstrap.cmd` | TODO |
| `build_usb.ps1` | TODO |
| End-to-end test on bare metal | TODO |

## For now

Use the supported path: install Windows 11 manually from the official
Microsoft USB tool, then run `..\install.ps1` from an elevated PowerShell
prompt. That gets you to the same end state.

Contributions welcome — PRs that fill in any of the four pieces above are
the easiest way to help.
