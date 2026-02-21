# netlab-wireguard-coredns-basic

Production-ready reference implementation for a private intranet stack using WireGuard + CoreDNS + Docker with Terraform/Ansible automation.

## Documentation

- Project overview and workflow: [docs/README.md](docs/README.md)
- End-to-end runbook: [docs/RUNNING.md](docs/RUNNING.md)
- Architecture details: [docs/architecture.md](docs/architecture.md)

## One-command client onboarding

```bash
curl -fsSL https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh | bash -s -- --server-endpoint 172.25.242.222:51820 --server-ssh subtilizer@172.25.242.222
```
