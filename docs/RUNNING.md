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

### Automatic local configuration (recommended)

Run:

```bash
make local-config
```

What `local-config.sh` does:
- Loads `SUDO_PASSWORD` from `.env` (prompts once and stores it if missing).
- Detects local server endpoint/IP dynamically.
- Detects SSH user, SSH port, and SSH private key path dynamically.
- Creates an SSH key if missing.
- Installs/starts local SSH server on port `22` if not available.
- Writes `infra/terraform/terraform.tfvars` with a ready-to-provision configuration.

Required input:
- Only `.env` sudo password.

No other manual configuration is required for a default local setup.

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

Unix/Linux/macOS one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh | bash -s -- --server-endpoint 172.25.242.222:51820 --server-ssh subtilizer@172.25.242.222
```

Windows PowerShell one-liner (auto-detects Git Bash or WSL):

```powershell
$u='https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh'; $a='--server-endpoint 172.25.242.222:51820 --server-ssh subtilizer@172.25.242.222'; $b=(Get-Command bash -ErrorAction SilentlyContinue).Source; if(-not $b){$c=@("$env:ProgramFiles\Git\bin\bash.exe","$env:ProgramFiles\Git\usr\bin\bash.exe","$env:ProgramW6432\Git\bin\bash.exe","$env:ProgramW6432\Git\usr\bin\bash.exe"); $b=$c | Where-Object { Test-Path $_ } | Select-Object -First 1}; if($b){ & $b -lc "curl -fsSL $u | bash -s -- $a" } elseif(Get-Command wsl -ErrorAction SilentlyContinue){ wsl bash -lc "curl -fsSL $u | bash -s -- $a" } else { throw 'Bash runtime not found. Install Git for Windows or WSL.' }
```

Note: `connect-client.sh` auto-detects Windows OpenSSH (`ssh.exe`/`scp.exe`) and `curl.exe` when running in Git Bash or WSL-style shells, so manual PATH updates are not required.

How password authentication works:
- Script does **not** register users.
- Script always prompts for login authentication (`Login user`, `Login password`).
- Credentials are validated **server-side** by `/opt/netlab/auth/validate_user.sh` against `/opt/netlab/auth/users.yml`.
- The client does not read or require direct access to `users.yml`.
- Client sends login/password to the validator over SSH stdin (prevents shell quoting issues with special characters).
- If authentication succeeds, VPN setup continues automatically.
- If authentication fails, the client prints only: `Authentication failed: invalid user or password.`

Pre-registered users source (extensible and gitignored):
- `infra/ansible/group_vars/users.yml`
- Add entries with `username`, `password_hash`, `client_name`, and `vpn_ip`
- Set `vpn_ip: auto` for dynamic allocation from the WireGuard subnet

Server generation step:
- `make config` copies configured users to server-only `/opt/netlab/auth/users.yml` and installs `/opt/netlab/auth/validate_user.sh`.
- Client authentication calls the validator through `sudo -n` on the server; the client never reads `users.yml` directly.

Troubleshooting authentication failures:
- Re-run `make config` to regenerate server-side auth assets and user profiles.
- Ensure you enter login/password exactly; Windows CRLF input is normalized by the client script.
- If server was provisioned with an older auth helper, re-running `make config` updates it; client also includes compatibility fallback during rollout.
- Check server auth events in `/opt/netlab/auth/auth.log` (contains username + status only).
- If credentials are invalid, client output is only: `Authentication failed: invalid user or password`.

Optional debug mode (for troubleshooting only):

```bash
curl -fsSL https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh | NETLAB_AUTH_DEBUG=1 bash -s -- --server-endpoint 172.25.242.222:51820 --server-ssh subtilizer@172.25.242.222
```

When enabled, the client prints server-side validator diagnostics without exposing passwords.

Local smoke-test users created by default:
- Username: `demo` / Password: `Demo!Netlab#2026`
- Username: `ops` / Password: `Ops!Netlab#2026`

What the script configures automatically:
- Downloads the pre-generated user profile from `/opt/netlab/wg-clients/<client>.conf`.
- If `wg` is available, applies and starts local `wg0`.
- Validates DNS and HTTP reachability for `service1.intranet.local`.

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

### Client connection (Linux and Windows)

Unix/Linux/macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh | bash -s -- --server-endpoint 172.25.242.222:51820 --server-ssh subtilizer@172.25.242.222
```

Windows PowerShell:

```powershell
$u='https://raw.githubusercontent.com/lcfranca/netlab-wireguard-coredns-basic/main/connect-client.sh'; $a='--server-endpoint 172.25.242.222:51820 --server-ssh subtilizer@172.25.242.222'; $b=(Get-Command bash -ErrorAction SilentlyContinue).Source; if(-not $b){$c=@("$env:ProgramFiles\Git\bin\bash.exe","$env:ProgramFiles\Git\usr\bin\bash.exe","$env:ProgramW6432\Git\bin\bash.exe","$env:ProgramW6432\Git\usr\bin\bash.exe"); $b=$c | Where-Object { Test-Path $_ } | Select-Object -First 1}; if($b){ & $b -lc "curl -fsSL $u | bash -s -- $a" } elseif(Get-Command wsl -ErrorAction SilentlyContinue){ wsl bash -lc "curl -fsSL $u | bash -s -- $a" } else { throw 'Bash runtime not found. Install Git for Windows or WSL.' }
```

Note: the script automatically resolves `ssh.exe`/`scp.exe` and `curl.exe` from Windows locations when Git Bash PATH does not include them.

If script shows `Missing required command: wg`:
- Install WireGuard for Windows: https://www.wireguard.com/install/
- Re-run `bash connect-client.sh ...` or import generated config from `%USERPROFILE%\\.config\\netlab-wireguard\\wg0.conf` into the WireGuard UI and activate tunnel.

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
- Stored items: connection defaults and last login user
- User/password are validated against server-side pre-registered user database
- If authentication fails, output is only: `Authentication failed: invalid user or password.`

### Supported script parameters

`connect-client.sh` supports:
- `--server-endpoint <ip:port>`
- `--server-ssh <user@host>`
- `--interface <wg-if>`

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
