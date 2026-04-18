# Intel Arc Pro B70 LLM Inference Server — Windows Edition

Windows installer for the **Intel Arc Pro B70** vLLM inference stack (WSL2 + Docker + vLLM XPU tensor parallelism across all 4 cards, single-model maximum throughput).

## The three-repo picture

| Repo | What it does | When you want it |
|---|---|---|
| **this repo** | Windows (WSL2 + Docker) installer for vLLM XPU TP=4 — one big model sharded across 4 B70s | Windows workstation, want max single-model throughput (~540 tok/s on 4× B70) |
| [arc-pro-b70-inference-setup-ubuntu-server](https://github.com/Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server) | Bare-metal Ubuntu autoinstall ISO, BIOS/hardware guide, DDR4 tuning, firstboot service | Building the box from scratch (Linux host, no WSL2 overhead) |
| [arc-pro-b70-ubuntu-gpu-speedup-bugfixes](https://github.com/Hal9000AIML/arc-pro-b70-ubuntu-gpu-speedup-bugfixes) | llama.cpp (not vLLM) tuning kit: 11 cherry-picks + Mesa 26 + backend rules. Runs multiple different models concurrently, one per card | You need multi-tier inference (chat + code + fast + reasoning at once), not a single sharded model |

**Choosing between this repo and the llama.cpp kit:** if your workload is "one model, max tok/s" use this (vLLM TP=4). If your workload is "several models, different sizes, all available at once" use the llama.cpp kit. vLLM cannot run multiple models on one TP=4 deployment; llama.cpp cannot shard one model across GPUs.

## How It Works

vLLM XPU has no native Windows build — it requires Level Zero / SYCL on Linux,
and Intel oneCCL multi-GPU is Linux-only. This installer therefore uses **WSL2 +
Ubuntu 24.04** as the runtime, with Intel Arc GPU passthrough into WSL via
the Intel Arc Pro Windows driver.

```
┌──────────────────────────────────────────────────┐
│  Windows 11                                      │
│                                                  │
│  Intel Arc Pro Windows Driver                    │
│  (Level Zero loader, SYCL runtime)               │
│           │                                      │
│           ▼ GPU passthrough                      │
│  ┌─────────────────────────────────────────┐    │
│  │  WSL2 Ubuntu 24.04 (systemd enabled)    │    │
│  │                                         │    │
│  │  Docker → vllm-b70 container            │    │
│  │           ↓                             │    │
│  │  vLLM XPU (TP=4) → 4× B70               │    │
│  │  OpenAI API on 0.0.0.0:8000             │    │
│  └─────────────────────────────────────────┘    │
│                  │                               │
└──────────────────┼───────────────────────────────┘
                   ▼
            LAN clients (any OS)
            curl http://<host>:8000/v1/...
```

The actual setup of the vLLM stack inside WSL is delegated to the proven
`odin-b70-setup.sh` from the
[Ubuntu repo](https://github.com/Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server),
so both editions stay in sync. Fixes pushed there flow into Windows installs
automatically. This includes the hardening pushed in the Ubuntu repo
commit `2806ef6`:

- HTTP-health-based idempotency guard in `start_vllm.sh` (replaces the
  previous pgrep-based check that was fooled by orphaned worker processes
  after a vLLM crash).
- HTTP-health-based watchdog in `watchdog_vllm.sh` with a 10-minute startup
  grace period, 60-second consecutive failure threshold, and automatic
  cleanup of leaked shared-memory segments between restarts.
- `tee -a` for `/tmp/vllm.log` so pre-hang debug context survives restarts.
- Intel Battlemage GuC firmware 70.60.0 (and HuC 8.2.10) pulled from
  kernel.org linux-firmware.git HEAD, zstd-compressed and installed as
  `/lib/firmware/xe/bmg_guc_70.bin.zst`, addressing blitter-engine (bcs)
  hangs observed on older 70.44.1 that cascaded into vLLM EngineCore RPC
  timeouts. The xe driver loads `.bin.zst`, so the file MUST be zstd
  compressed — installing a raw `.bin` will crash all GPUs with -EINVAL.
  Requires a reboot (inside WSL: `wsl --shutdown` then restart) to
  activate.

## Requirements

- Windows 10 build 19041+ (2004) or **Windows 11** (recommended)
- CPU virtualization enabled in BIOS (AMD-V / Intel VT-x + SVM)
- 16+ GB RAM (128 GB strongly recommended for full throughput — see Ubuntu README)
- 4× Intel Arc Pro B70 (or fewer; install adapts to detected GPU count)
- 100 GB free on `C:` for WSL distro + vLLM image + Gemma 4 weights
- Internet connection (Docker pulls + vLLM source build inside WSL)

## Quick Start

```powershell
# Open PowerShell as Administrator
git clone https://github.com/Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server-windows.git
cd arc-pro-b70-inference-setup-windows

Set-ExecutionPolicy -Scope Process Bypass -Force
.\install.ps1
```

The installer is **idempotent** — if it asks you to reboot (after enabling WSL
features), reboot and re-run `.\install.ps1`. It resumes from the next step
based on `C:\ProB70\state.json`.

### What it does

1. **Preflight** — checks Windows build, virtualization, detects Intel Arc GPUs
2. **WSL features** — enables `Microsoft-Windows-Subsystem-Linux` + `VirtualMachinePlatform`, prompts reboot
3. **WSL kernel** — `wsl --update`, sets default version to 2
4. **Ubuntu 24.04** — installs the distro, you create a username (`user` recommended)
5. **Intel drivers** — opens the Intel Arc Pro driver download page; you install + reboot
6. **systemd in WSL** — writes `/etc/wsl.conf` with `systemd=true` (required for the vLLM systemd services)
7. **Ubuntu setup** — clones the Ubuntu repo inside WSL and runs `odin-b70-setup.sh` (30-60 min)
8. **Start Menu shortcuts** — Start vLLM, Stop vLLM, View Logs, GPU Temps

When done:

```
Start Menu → Intel B70 Inference → Start vLLM Server
```

Then test from any LAN client:

```bash
curl http://<windows-host>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma-4-26B-A4B","messages":[{"role":"user","content":"Hello"}],"max_tokens":100}'
```

## Bootable USB (unattended Windows install)

Unlike Ubuntu's `cloud-init` autoinstall, Windows has no clean equivalent.
A fully unattended Windows install USB requires:

1. Windows 11 ISO from Microsoft
2. **Windows ADK** + Windows System Image Manager
3. A custom `autounattend.xml` placed at the root of the USB
4. A `SetupComplete.cmd` first-logon script that calls `install.ps1`

A reference `autounattend.xml` and build script are tracked under
[`unattended_usb/`](unattended_usb/) — **work in progress**, see that
folder's README. For now, the supported path is: install Windows manually,
then run `install.ps1`.

## Idempotency & State

State is tracked in `C:\ProB70\state.json`:

```json
{ "LastStep": "ubuntu_setup", "Timestamp": "2026-04-06T18:30:00.000Z" }
```

To re-run a specific step, edit `state.json` and set `LastStep` to the step
**before** the one you want to run, then re-run `.\install.ps1`. Steps in order:

```
preflight → wsl_features → wsl_kernel → wsl_distro →
intel_drivers → wsl_systemd → ubuntu_setup → shortcuts → done
```

Full transcript log: `C:\ProB70\install.log`.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `wsl --install` says feature not enabled | Reboot — the install script tells you to. If you skipped, re-run from `wsl_features`. |
| `wsl --update` fails | Manually install the WSL2 kernel: <https://aka.ms/wsl2kernel> |
| GPUs not visible inside WSL | Make sure you installed the **Intel Arc Pro Graphics** driver (not the consumer Arc driver) and rebooted. Verify: `wsl -d Ubuntu-24.04 -- ls /dev/dri/` should show `card0`+ devices. |
| systemd not running in WSL | Check `/etc/wsl.conf` has `[boot]\nsystemd=true`, then `wsl --shutdown` and re-launch. |
| vLLM container fails inside WSL | The Ubuntu setup script's troubleshooting table applies — see [Ubuntu README](https://github.com/Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server#troubleshooting). |
| LAN clients can't reach port 8000 | Add a Windows Firewall rule: `New-NetFirewallRule -DisplayName "vLLM" -Direction Inbound -LocalPort 8000 -Protocol TCP -Action Allow`. WSL2 forwards localhost automatically but external traffic needs the firewall opened. |
| Slow inference vs native Ubuntu | WSL2 GPU passthrough adds ~5-15% overhead vs bare metal. For maximum throughput, use the Ubuntu Server edition. |

## Why Not Native Windows?

Tracked here for reference — these are the blockers as of April 2026:

- **vLLM** has no Windows build. Intel publishes vLLM XPU only as Linux Docker images and Linux source tarballs.
- **oneCCL** (used for inter-GPU all-reduce in tensor parallelism) is Linux-only.
- **Level Zero IPC** between processes works on Windows but the SYCL runtime + vLLM combination is unsupported.
- llama.cpp **Vulkan** runs natively on Windows for single-GPU but multi-GPU is broken (sequential pipeline, ~4× slowdown — bug llama.cpp#16767).

If a future native Windows path opens up, this installer will switch to it
without requiring users to reinstall.

## License

MIT
