# Architecture

## Components

- **WireGuard (`wg0`)**
  - Private subnet: `10.0.0.0/24`
  - Server IP: `10.0.0.1`
  - UDP port: `51820`

- **CoreDNS**
  - Zone: `intranet.local`
  - Records:
    - `service1.intranet.local -> 10.0.0.1`
    - `db.intranet.local -> 10.0.0.2`
  - External recursion: forward to `8.8.8.8` and `1.1.1.1`

- **Container Service**
  - Nginx-based service
  - Exposed by server and consumed via VPN + DNS name

## Provisioning Flow

1. Terraform generates Ansible inventory.
2. Ansible configures WireGuard and generates client profiles.
3. Ansible deploys CoreDNS container with mounted zone files.
4. Ansible deploys service container through Docker Compose.
5. Validation script checks DNS + HTTP access path.

## Security Notes

- WireGuard keys are generated on the server and stored under `/etc/wireguard`.
- Client profiles are emitted with file mode `0600`.
- CoreDNS runs with read-only mounted configuration files.
- The project avoids proprietary control planes and is driven by open tools and files.
