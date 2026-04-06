# install.ps1 — Windows installer for Intel Arc Pro B70 LLM Inference Server
#
# Sets up the full vLLM XPU stack on Windows by leveraging WSL2 + Ubuntu 24.04.
# WSL2 is the only path because:
#   - vLLM XPU requires Level Zero / SYCL on Linux; no native Windows build exists
#   - Intel oneCCL multi-GPU is Linux-only
#   - Docker for the vLLM container needs systemd, which only works under WSL2
#
# Run from an elevated PowerShell prompt (Run as Administrator):
#   Set-ExecutionPolicy -Scope Process Bypass -Force
#   .\install.ps1
#
# Idempotent: re-running picks up where it left off (state in C:\ProB70\state.json).

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

$StateDir  = "C:\ProB70"
$StateFile = "$StateDir\state.json"
$LogFile   = "$StateDir\install.log"
$WSLDistro = "Ubuntu-24.04"
$WSLUser   = "user"

# Ubuntu repo with the actual setup script
$UbuntuRepo = "https://github.com/Hal9000AIML/arc-pro-b70-inference-setup.git"

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
Start-Transcript -Path $LogFile -Append | Out-Null

function Save-State {
    param($Step)
    @{ LastStep = $Step; Timestamp = (Get-Date).ToString("o") } |
        ConvertTo-Json | Set-Content $StateFile
    Write-Host ">>> Step complete: $Step" -ForegroundColor Green
}

function Get-State {
    if (Test-Path $StateFile) {
        return (Get-Content $StateFile | ConvertFrom-Json).LastStep
    }
    return ""
}

function Step-Required {
    param($Step, $Steps)
    return ($Steps.IndexOf($Step) -gt $Steps.IndexOf((Get-State)))
}

$Steps = @(
    "preflight",
    "wsl_features",
    "wsl_kernel",
    "wsl_distro",
    "intel_drivers",
    "wsl_systemd",
    "ubuntu_setup",
    "shortcuts",
    "done"
)

Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host " Intel Arc Pro B70 — Windows Installer" -ForegroundColor Cyan
Write-Host " (WSL2 + Ubuntu 24.04 + vLLM XPU)" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""

# ─── Step 1: Preflight ──────────────────────────────────────────────────────
if (Step-Required "preflight" $Steps) {
    Write-Host ">>> [1/8] Preflight checks" -ForegroundColor Yellow

    # Windows version (WSL2 needs Windows 10 2004+ or Windows 11)
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    if ($build -lt 19041) {
        throw "Windows build $build is too old. Need 19041+ (Windows 10 2004 or Windows 11)."
    }
    Write-Host "  Windows build: $build OK"

    # Check virtualization is enabled in BIOS
    $cpu = Get-CimInstance Win32_Processor
    if (-not $cpu.VirtualizationFirmwareEnabled) {
        Write-Warning "CPU virtualization may be disabled in BIOS. WSL2 will fail without it."
        Write-Warning "Enable AMD-V/Intel VT-x and SVM in BIOS, then re-run."
    }

    # Detect Intel Arc GPUs
    $gpus = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match "Arc" -or $_.Name -match "B70" }
    if ($gpus) {
        Write-Host "  Detected Intel Arc GPUs:" -ForegroundColor Green
        $gpus | ForEach-Object { Write-Host "    - $($_.Name)" }
    } else {
        Write-Warning "No Intel Arc GPUs detected. Driver install will still proceed."
    }

    Save-State "preflight"
}

# ─── Step 2: Enable WSL features ────────────────────────────────────────────
if (Step-Required "wsl_features" $Steps) {
    Write-Host ">>> [2/8] Enabling WSL2 + Virtual Machine Platform" -ForegroundColor Yellow
    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
    Save-State "wsl_features"

    Write-Host ""
    Write-Host "*** REBOOT REQUIRED ***" -ForegroundColor Red
    Write-Host "Reboot, then re-run this script. It will resume from the next step."
    $resp = Read-Host "Reboot now? (y/N)"
    if ($resp -eq "y") { Restart-Computer -Force }
    Stop-Transcript | Out-Null
    exit 0
}

# ─── Step 3: WSL kernel + default version ───────────────────────────────────
if (Step-Required "wsl_kernel" $Steps) {
    Write-Host ">>> [3/8] Installing WSL2 kernel + setting default" -ForegroundColor Yellow
    wsl --update
    wsl --set-default-version 2
    Save-State "wsl_kernel"
}

# ─── Step 4: Install Ubuntu 24.04 distro ────────────────────────────────────
if (Step-Required "wsl_distro" $Steps) {
    Write-Host ">>> [4/8] Installing $WSLDistro" -ForegroundColor Yellow
    $installed = (wsl -l -q) -replace "`0",""
    if ($installed -notmatch $WSLDistro) {
        wsl --install -d $WSLDistro --no-launch
        Write-Host ""
        Write-Host "Ubuntu installed. Launching for first-run user creation..." -ForegroundColor Cyan
        Write-Host "When prompted, create user '$WSLUser' with any password you like."
        Write-Host "After the prompt completes, type 'exit' to return here."
        Start-Process -Wait wsl -ArgumentList "-d", $WSLDistro
    } else {
        Write-Host "  $WSLDistro already installed."
    }
    Save-State "wsl_distro"
}

# ─── Step 5: Intel Arc Windows drivers ──────────────────────────────────────
if (Step-Required "intel_drivers" $Steps) {
    Write-Host ">>> [5/8] Intel Arc Pro driver" -ForegroundColor Yellow
    Write-Host "  Opening Intel driver download page in your browser."
    Write-Host "  Download and install the latest 'Intel Arc Pro Graphics Driver'."
    Write-Host "  The Pro driver bundle includes the Level Zero loader needed for"
    Write-Host "  GPU compute passthrough into WSL2."
    Start-Process "https://www.intel.com/content/www/us/en/download/785597/intel-arc-pro-graphics-windows.html"
    Read-Host "Press Enter once the Intel driver install is complete and you have rebooted (if it asked)"
    Save-State "intel_drivers"
}

# ─── Step 6: Enable systemd in WSL ──────────────────────────────────────────
if (Step-Required "wsl_systemd" $Steps) {
    Write-Host ">>> [6/8] Enabling systemd in WSL" -ForegroundColor Yellow
    # The Ubuntu setup script creates systemd units; needs systemd in WSL
    $wslConf = @"
[boot]
systemd=true

[user]
default=$WSLUser

[interop]
appendWindowsPath=false
"@
    $wslConf | wsl -d $WSLDistro -u root tee /etc/wsl.conf | Out-Null
    wsl --shutdown
    Start-Sleep -Seconds 5
    # Verify systemd came up
    $check = wsl -d $WSLDistro -- bash -c "systemctl is-system-running 2>/dev/null || true"
    Write-Host "  systemd status: $check"
    Save-State "wsl_systemd"
}

# ─── Step 7: Run the Ubuntu setup script inside WSL ─────────────────────────
if (Step-Required "ubuntu_setup" $Steps) {
    Write-Host ">>> [7/8] Running Ubuntu setup inside WSL" -ForegroundColor Yellow
    Write-Host "  This builds vLLM from source. Expect 30-60 minutes."
    Write-Host ""

    $setupCmd = @"
set -e
cd ~
if [ ! -d arc-pro-b70-inference-setup ]; then
    sudo apt-get update
    sudo apt-get install -y git
    git clone $UbuntuRepo
fi
cd arc-pro-b70-inference-setup
git pull
chmod +x odin-b70-setup.sh
sudo ./odin-b70-setup.sh
"@
    wsl -d $WSLDistro -u $WSLUser -- bash -c $setupCmd
    Save-State "ubuntu_setup"
}

# ─── Step 8: Windows shortcuts ──────────────────────────────────────────────
if (Step-Required "shortcuts" $Steps) {
    Write-Host ">>> [8/8] Creating Start Menu shortcuts" -ForegroundColor Yellow
    $startMenu = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Intel B70 Inference"
    New-Item -ItemType Directory -Force -Path $startMenu | Out-Null

    function New-Shortcut {
        param($Name, $Args)
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut("$startMenu\$Name.lnk")
        $sc.TargetPath = "wsl.exe"
        $sc.Arguments = $Args
        $sc.Save()
    }
    New-Shortcut "Start vLLM Server"  "-d $WSLDistro -u $WSLUser -- bash -ic '~/boot_vllm.sh'"
    New-Shortcut "Stop vLLM Server"   "-d $WSLDistro -u $WSLUser -- bash -ic '~/stop_vllm.sh'"
    New-Shortcut "vLLM Logs"          "-d $WSLDistro -u $WSLUser -- bash -ic 'docker exec vllm-b70 tail -f /tmp/vllm.log'"
    New-Shortcut "GPU Temps"          "-d $WSLDistro -u $WSLUser -- bash -ic 'sensors | grep -A3 xe-pci'"

    Save-State "shortcuts"
}

Save-State "done"

Write-Host ""
Write-Host "===============================================" -ForegroundColor Green
Write-Host " Install complete!" -ForegroundColor Green
Write-Host "===============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Start the inference server:"
Write-Host "  Start Menu  → Intel B70 Inference → Start vLLM Server"
Write-Host "  Or CLI      → wsl -d $WSLDistro -u $WSLUser -- ~/boot_vllm.sh"
Write-Host ""
Write-Host "Test from any LAN client:"
Write-Host "  curl http://<this-machine>:8000/v1/models"
Write-Host ""
Write-Host "Logs: $LogFile"

Stop-Transcript | Out-Null
