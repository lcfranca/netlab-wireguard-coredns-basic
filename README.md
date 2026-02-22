# netlab-wireguard-coredns-basic

Production-ready reference implementation for a private intranet stack using WireGuard + CoreDNS + Docker with Terraform/Ansible automation.

## Documentation

- Project overview and workflow: [docs/README.md](docs/README.md)
- End-to-end runbook: [docs/RUNNING.md](docs/RUNNING.md)
- Mirror runbook (single cross-platform command): [.docs/RUNNING.md#client-connection-linux-and-windows](.docs/RUNNING.md#client-connection-linux-and-windows)
- Client connection (Linux + Windows): [docs/RUNNING.md#client-connection-linux-and-windows](docs/RUNNING.md#client-connection-linux-and-windows)
- Client authentication behavior: [docs/RUNNING.md#4-connect-another-computer-to-vpn-single-command](docs/RUNNING.md#4-connect-another-computer-to-vpn-single-command)
- Auth troubleshooting: [docs/RUNNING.md#4-connect-another-computer-to-vpn-single-command](docs/RUNNING.md#4-connect-another-computer-to-vpn-single-command)
- Dependency auto-detection/install: [docs/RUNNING.md#4-connect-another-computer-to-vpn-single-command](docs/RUNNING.md#4-connect-another-computer-to-vpn-single-command)
- Local auto-configuration: [docs/RUNNING.md#2-configure-terraform-variables](docs/RUNNING.md#2-configure-terraform-variables)
- Architecture details: [docs/architecture.md](docs/architecture.md)

## One-command client onboarding

```bash
curl -fsSL https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh | bash -s -- --server-endpoint 172.25.242.222:51820 --server-ssh subtilizer@172.25.242.222
```

Windows single-command connect:

```powershell
$u="https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/fetch-wireguard-conf.ps1?v=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"; $s=Join-Path $env:TEMP 'fetch-wireguard-conf.ps1'; Remove-Item $s -Force -ErrorAction SilentlyContinue; Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $s; & $s -ServerSsh subtilizer@172.25.242.222 -ClientName client-demo -Interface wg0
```

Linux/macOS fallback profile downloader:

```bash
curl -fsSL https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/fetch-wireguard-conf.sh | bash -s -- --server-ssh subtilizer@172.25.242.222 --client-name client-demo --interface wg0
```

If SSH key is not authorized on server, add `-InteractiveSsh` (PowerShell) or `--interactive-ssh` (Linux/macOS).

On Windows, if DNS is not immediately updated after tunnel activation, the script adds hosts fallback for `service1.intranet.local` -> `10.0.0.1` and flushes DNS.
If an existing tunnel service is stale, the script reinstalls it automatically. Prefer running PowerShell as Administrator.
