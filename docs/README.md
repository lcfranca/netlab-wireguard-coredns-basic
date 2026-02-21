# netlab-wireguard-coredns-basic

Minimal private intranet lab with:
- WireGuard VPN (`10.0.0.0/24`)
- CoreDNS private zone (`intranet.local`)
- Internal containerized service (`service1.intranet.local`)
- End-to-end automation with Terraform, Ansible, shell scripts, Makefile, and GitHub Actions.

## Start Here

- Full runbook: [docs/RUNNING.md](RUNNING.md)
- Architecture: [docs/architecture.md](architecture.md)

## Architecture Summary

- **Terraform** generates the working Ansible inventory based on input variables.
- **Ansible** configures:
  - WireGuard server and optional clients
  - CoreDNS container with private zone records
  - Docker engine and internal demo service container
- **CoreDNS** resolves `service1.intranet.local` to WireGuard server IP (`10.0.0.1`).
- **Service container** is exposed on server and reachable only over VPN route.

## Prerequisites

On the machine running automation:
- Linux (Ubuntu/Debian recommended)
- `terraform >= 1.5`
- `ansible-core`
- SSH key-based access to server/clients with sudo privileges

On target server/client hosts:
- Linux with internet access for package installation

## Quick Start

0. Install dependencies:

```bash
make deps
```

Dependency check only:

```bash
make deps-check
```

1. Prepare Terraform variables:

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars with your server/client host IPs and users
```

2. Generate inventory:

```bash
cd ../..
make infra
```

3. Configure VPN and DNS:

```bash
make config
```

4. Deploy internal service:

```bash
make deploy
```

5. Run basic connectivity checks from a VPN-connected client or the server:

```bash
make test
```

## Operational Commands

- `make tf-validate` — Terraform fmt + validate
- `make ansible-lint` — Ansible syntax checks
- `make clean` — Destroy Terraform local state artifacts and generated inventory

## Client Profiles

Generated WireGuard client profiles are stored on the server at:

- `/opt/netlab/wg-clients/<client-name>.conf`

If clients are included in inventory and reachable, Ansible also installs and applies their profile automatically.

## One-command client setup

```bash
curl -fsSL https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh | bash -s -- --server-endpoint 172.25.242.222:51820 --server-ssh subtilizer@172.25.242.222
```
