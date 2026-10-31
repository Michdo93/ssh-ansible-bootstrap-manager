# SSH Ansible Bootstrap Manager

Prepares hosts for Ansible from the **control node**: it logs in once with an existing administrator account, detects the operating system, uploads the matching bootstrap script and runs it as root/Administrator. The bootstrap creates a dedicated Ansible account (name of your choice), sets its password, installs the control node's SSH public key and configures privilege escalation.

It is used automatically by [ansible-inventory-generator](https://github.com/Michdo93/ansible-inventory-generator) (recommended: that tool also writes the inventory and the Ansible Vault). It can also be run on its own.

## What it does

1. **SSH key pair**: uses `~/.ssh/id_ed25519`, `id_ecdsa` or `id_rsa`; generates an ed25519 key if none exists (`--key` / `BM_KEY_FILE` to choose another). A missing `.pub` is derived from the private key.
2. **Host keys**: the first contact is accepted automatically (`StrictHostKeyChecking=accept-new`, i.e. "yes" to the fingerprint question). A changed host key (e.g. after reinstalling a VM) is never accepted silently; in interactive runs you are asked whether to remove the stale `known_hosts` entry.
3. **Admin login**: password (via `sshpass`, or `SSH_ASKPASS` with OpenSSH ≥ 8.4) or SSH key/agent. Works for `root`, for sudo users with or without password, and for Windows administrators (cmd or PowerShell as default shell).
4. **Provider**: selected from `providers.sh` by the OS ID and **uploaded from the control node** - targets need no `curl` and do not fetch code from the Internet. A checkout of the provider repository next to this one (or in `./vendor`, or `$BOOTSTRAP_PROVIDER_DIR`) is preferred over the URL.
5. **Secrets**: the account password (and a sudo password, if needed) is sent through the SSH channel's stdin (Linux) or a temporary file in the administrator's profile that is deleted immediately (Windows). It never appears in a process list or on the screen.
6. **Verification**: key-based login as the new account must work at the end.

## Providers

| Platform | Provider | Script |
| --- | --- | --- |
| Windows | `windows` | [ansible-windows-bootstrap](https://github.com/Michdo93/ansible-windows-bootstrap) `bootstrap.ps1` |
| Kali Linux / Kali Purple | `kali` | [ansible-kali-bootstrap](https://github.com/Michdo93/ansible-kali-bootstrap) `bootstrap-ansible-user.sh` |
| Other Linux (Debian family) | `linux` | [ansible-linux-bootstrap](https://github.com/Michdo93/ansible-linux-bootstrap) `bootstrap-ansible-user.sh` |

Record format in `providers.sh`: `id|OS_ID_regex|execution_type|URL` (first match wins, regex is anchored; use `[]`/`()` for alternatives, not `|`).

Interfaces expected from providers:

- `shell`: Bash script, run as root: `bootstrap.sh username=<name> ssh_public_key='<key>' sudo_mode=vault|nopasswd password_stdin=1` (password on the first stdin line).
- `powershell`: script with `-Username`, `-Password`, `-PublicKey`, run elevated.

## Requirements

Control node: Bash 4+, OpenSSH client (`ssh`, `scp`, `ssh-keygen`), coreutils, and `sshpass` or OpenSSH ≥ 8.4. Targets: SSH reachable; Linux needs `bash`, `base64` and root or sudo; Windows needs OpenSSH Server with SFTP (default).

## Usage

Interactive (scan a range, bootstrap each host):

```bash
chmod +x bootstrap-manager.sh
./bootstrap-manager.sh
```

Single host:

```bash
./bootstrap-manager.sh --host 192.168.0.20 --admin-user pi --user ansible
./bootstrap-manager.sh --host 192.168.0.30 --port 2222 --admin-user root --user sysadmin --sudo-mode nopasswd
```

Non-interactive: set `BOOTSTRAP_ADMIN_PASSWORD` (empty = key/agent) and `BOOTSTRAP_ACCOUNT_PASSWORD`.

`--sudo-mode vault` (default) writes `<user> ALL=(ALL:ALL) ALL` - Ansible then needs the account password, kept in Ansible Vault by the inventory generator. `--sudo-mode nopasswd` writes `<user> ALL=(ALL:ALL) NOPASSWD: ALL`.

## Library

`lib/bootstrap-lib.sh` contains all logic (`bm_ensure_keypair`, `bm_scan`, `bm_bootstrap_host`, `bm_gather_facts`, `bm_verify_become`, ...) and is sourced by the inventory generator.

## Security

- Review the provider scripts; prefer local reviewed checkouts or pin URLs to a commit.
- A changed host key is a warning sign; only accept it if you know the host was reinstalled.
- Generated private keys have no passphrase so that Ansible can run unattended; protect `~/.ssh` on the control node.
