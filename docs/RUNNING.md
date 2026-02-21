# RUNNING GUIDE

This guide explains how to deploy and validate the full stack: Terraform + Ansible + WireGuard + CoreDNS + Docker.

## 1) Prerequisites

Install on the automation machine:
- Terraform
- Ansible (`ansible-core`)
- Docker CLI
- WireGuard tools (`wg`, `wg-quick`) for client-side automation
- `curl` (DNS lookup tools are no longer required locally for `make test`)

Required on the provisioned server (installed automatically by Ansible):
- `curl`
- `dnsutils` (for `dig`)
- `iproute2` (for interface/listener checks)

Automated installer (Linux/macOS):

```bash
git clone <your-repo-url>
cd netlab-wireguard-coredns-basic
make deps
```

Create environment file for privileged provisioning:

```bash
cp .env.example .env
# edit .env and set SUDO_PASSWORD
```

Dependency check only:

```bash
make deps-check
```

## 2) Configure Terraform variables

The repository already includes:

```bash
infra/terraform/terraform.tfvars
```

Edit it with your real server/client values:
- `server_public_ip`
- `server_ssh_user`
- `server_ssh_port`
- `server_ssh_private_key_file`
- `client_hosts`
- `wireguard_subnet`
- `wireguard_server_ip`
- `dns_zone`
- `service_hostname`
- `service_container_image`
- `coredns_image`

`client_hosts` entries also support:
- `ssh_port`
- `ssh_private_key_file`

## 3) Provision host and configure services

From repository root:

```bash
make infra
make ssh-check
make config
make deploy
```

If the remote host requires sudo password (not passwordless sudo), store it in `.env`:

```bash
make config
make deploy
```

What each step does:
- `make infra`: Terraform generates `infra/ansible/generated/inventory.ini`
- `make ssh-check`: validates that SSH host/user/key/port in inventory are reachable
- `make config`: Ansible installs/configures WireGuard + CoreDNS on server (and optional clients)
- `make deploy`: Ansible installs Docker and deploys internal service container

Service exposure policy:
- Container is published only on `10.0.0.1:80` (WireGuard interface), not on all host interfaces.

## 4) Connect another computer to VPN (single command)

### Option A: Managed by inventory

If the client host is listed in `client_hosts`, `make config` provisions it automatically.

### Option B: Automated client script (recommended)

Run one command on the second computer, no clone required:

```bash
curl -fsSL https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh | bash -s -- --server-endpoint 172.25.242.222:51820 --server-ssh subtilizer@172.25.242.222
```

How password authentication works:
- First run: script prompts to create a profile password and confirms it.
- Script hashes and stores that password in `~/.config/netlab-wireguard/client.env` (mode `600`).
- Next runs: script prompts for the profile password and validates it against the stored hash.
- If validation succeeds, VPN setup continues automatically.

What the script configures automatically:
- Prompts for local and server sudo passwords (stored in the same profile file unless `--no-store` is used).
- Generates client keypair.
- Registers client peer on server and restarts server WireGuard.
- Installs/starts local `wg0` interface.
- Verifies route, DNS, and HTTP for `service1.intranet.local`.

Get server public key:

```bash
ssh <user>@<server-public-ip> "sudo cat /etc/wireguard/server_private.key | wg pubkey"
```

## 5) Access intranet service by internal hostname

On a VPN-connected client:

```bash
dig +short service1.intranet.local @10.0.0.1
curl -H "Host: service1.intranet.local" http://10.0.0.1
```

Fallback if `dig` is unavailable:

```bash
getent ahostsv4 service1.intranet.local
```

## 6) Validation checklist

Run:

```bash
make test
```

`make test` runs server-side checks over SSH using generated inventory and validates:
- DNS resolution from CoreDNS (`service1.intranet.local`)
- HTTP reachability over private/VPN path (`10.0.0.1`)
- Service is not bound to public/all interfaces
- Direct public-host HTTP path is rejected

Expected results:
- Host has WireGuard, CoreDNS, and Docker running
- Client connects to VPN (`wg show` shows handshake)
- Client resolves `service1.intranet.local`
- Client reaches the container over intranet path

If you see `ssh: connect to host ... timed out`:
1. Edit `infra/terraform/terraform.tfvars` and replace placeholder IPs (`203.0.113.x`) with real reachable host IPs.
2. Set valid `server_ssh_private_key_file` and (if used) `client_hosts[*].ssh_private_key_file`.
3. Rebuild inventory: `make infra`
4. Verify SSH first: `make ssh-check`
5. Re-run config: `make config`

## 7) Useful maintenance commands

```bash
make tf-validate
make ansible-lint
make clean
```

## 8) EXCLUSIVE: Connect from another PC

This section is only for the second computer (client) that will join the VPN and access intranet services.

### Required tools on the second PC

- WireGuard tools (`wg`, `wg-quick`, `systemctl`)
- `curl`
- Optional: `dig` (or use `getent`)

### One-command setup (no clone)

```bash
curl -fsSL https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh | bash -s -- --server-endpoint 172.25.242.222:51820 --server-ssh subtilizer@172.25.242.222
```

### Option A: Use generated client profile from server

1. Download profile:

```bash
scp <server-user>@<server-public-ip>:/opt/netlab/wg-clients/<client-name>.conf ./wg0.conf
```

2. Install and connect:

```bash
sudo install -m 600 ./wg0.conf /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
sudo wg show wg0
```

### Password validation and profile

- Profile file: `~/.config/netlab-wireguard/client.env`
- Stored items: hashed profile password + connection defaults + sudo credentials
- On every run, the script validates entered profile password against stored hash
- If password is wrong, setup aborts

### Optional custom parameters

```bash
curl -fsSL https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh | bash -s -- \
	--client-name client-2 \
	--server-endpoint 172.25.242.222:51820 \
	--server-ssh subtilizer@172.25.242.222 \
	--client-address 10.0.0.20/24 \
	--dns 10.0.0.1 \
	--allowed-ips 10.0.0.0/24
```

### Access intranet containers via internal hostname

After VPN is up:

```bash
dig +short service1.intranet.local @10.0.0.1
curl -H "Host: service1.intranet.local" http://10.0.0.1
```

Fallback if `dig` is unavailable:

```bash
getent ahostsv4 service1.intranet.local
```
