# SSH Ansible Bootstrap Manager

An interactive Bash manager that scans an IPv4 range for SSH services, identifies the remote OS, selects a configurable bootstrap provider, and runs the selected Ansible account bootstrap.

## Bootstrap repositories

This manager delegates the actual setup to these upstream repositories:

- [Windows Ansible Bootstrap](https://github.com/Michdo93/ansible-windows-bootstrap)
- [Kali Ansible Bootstrap](https://github.com/Michdo93/ansible-kali-bootstrap)
- [Linux Ansible Bootstrap](https://github.com/Michdo93/ansible-linux-bootstrap)

The Windows bootstrap is expected to leave its `upgrader.ps1` helper on the target as part of setup. See the Windows repository for the helper's location and usage details.

## Providers

Provider mappings live in [`providers.sh`](providers.sh), separate from the manager logic. Each record contains an ID, a regular expression matched against `/etc/os-release` `ID` (or `windows`), execution type, and script URL.

The default mappings are:

| Platform match | Provider | Entry point |
| --- | --- | --- |
| Windows | `windows` | `ansible-windows-bootstrap` `bootstrap.ps1` |
| Kali Linux (including Kali Purple, whose OS ID is Kali) | `kali` | `ansible-kali-bootstrap` `bootstrap-ansible-user.sh` |
| Other Linux IDs | `linux` | `ansible-linux-bootstrap` `bootstrap-ansible-user.sh` |

### Add another bootstrap script

The manager code does not need to change for a provider that uses one of the two supported interfaces. Add a record to the `BOOTSTRAP_PROVIDERS` array in `providers.sh` using this format:

```text
'provider-id|OS_ID_regex|execution_type|bootstrap_URL'
```

For example, to use a separate script for Fedora before the general Linux fallback:

```bash
  'fedora|fedora|shell|https://raw.githubusercontent.com/your-org/fedora-bootstrap/main/bootstrap.sh'
```

Place specific matches before broad matches such as `.*`; the manager selects the first matching record. The regular expression is matched against the `ID` value from Linux `/etc/os-release`. Windows uses the ID `windows`.

Use `shell` for a POSIX/Bash bootstrap that accepts the same argument interface as the current Linux providers:

```bash
curl -fsSL "$url" | sudo bash -s -- username="$username" password="$password"
```

Use `powershell` for a Windows script that accepts `-Username` and `-Password`. The target's OpenSSH default shell must be PowerShell. The URL should point directly to the script entry point.

If a new bootstrap needs different parameters, elevation behavior, package installation, or a different shell, update `bootstrap-manager.sh` to add a new execution type and implement its invocation. Also update this README with its prerequisites and security implications. Before adding a provider, confirm its OS detection ID and interface, check the script source, and try it on a disposable test host.

## Requirements

- Bash 4 or newer, OpenSSH client, `timeout`, and `sed`.
- Linux or WSL as the machine running this manager. SSH targets must listen on TCP port 22.
- Linux targets need a POSIX shell and an account that can use `sudo` (or root).
- Windows targets need OpenSSH Server configured with PowerShell as its default shell. The SSH account must have the rights required by the Windows bootstrap.
- Internet access from targets to `raw.githubusercontent.com`.
- Package manager and administrator access on Linux if `curl` must be installed.

The script checks whether `curl` exists on Linux and attempts installation with `apt-get`, `dnf`, `yum`, `pacman`, or `zypper` before running a shell provider. The provider command uses `sudo bash`, matching the upstream interface supplied for these repositories.

## Run

```bash
chmod +x bootstrap-manager.sh
./bootstrap-manager.sh
```

Enter and confirm the IPv4 range. For each SSH-reachable device, choose whether to continue, provide the SSH username, then enter and confirm the new Ansible account username and password. Password input is hidden. The manager detects the platform, chooses the matching provider, asks for confirmation, and reports success or failure before continuing to the next host.

Yes accepts `y`, `Y`, `yes`, or `Yes`; No accepts `n`, `N`, `no`, or `No`. Enter chooses the displayed default. SSH authentication is attempted up to three times per device.

## Security considerations

This tool downloads and executes remote scripts. Review the provider code and pin a reviewed commit or release before using it on important systems; the default URLs track the `main` branch. Host key verification is enabled, and the first connection may prompt you to verify a fingerprint.

The upstream bootstrap interfaces take the new account password as a command-line argument. That can expose it briefly to privileged process inspection on the remote host. The manager hides password input and does not write credentials to local files, but cannot eliminate that exposure without changing the provider interfaces. Use a unique temporary password and rotate it if the provider or target is not fully trusted.

Linux bootstrap currently uses `sudo bash`, so the SSH account must have working sudo access (or the provider command must be customized for a root SSH account). The Windows invocation depends on the SSH server's PowerShell shell configuration. Bootstrap output may include system details and is shown on failures for diagnosis.

## Limitations

- IPv4 only; maximum range size is 65,536 addresses.
- SSH TCP port 22 only.
- OS identification expects `/etc/os-release` and `uname` for Linux, or a PowerShell-based Windows OpenSSH server.
- The generic `linux` provider is currently the fallback for any non-Kali Linux ID. Review or add provider records if a distribution needs a different script.
