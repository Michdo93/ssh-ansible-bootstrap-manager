# SSH Ansible Bootstrap Manager

An interactive Bash manager that scans an IPv4 range for SSH services, identifies the remote OS, selects a configurable bootstrap provider, and runs the selected Ansible account bootstrap.

## Providers

Provider mappings live in [`providers.sh`](providers.sh), separate from the manager logic. Each record contains an ID, a regular expression matched against `/etc/os-release` `ID` (or `windows`), execution type, and script URL.

The default mappings are:

| Platform match | Provider | Entry point |
| --- | --- | --- |
| Windows | `windows` | `ansible-windows-bootstrap` `bootstrap.ps1` |
| Kali Linux (including Kali Purple, whose OS ID is Kali) | `kali` | `ansible-kali-bootstrap` `bootstrap-ansible-user.sh` |
| Other Linux IDs | `linux` | `ansible-linux-bootstrap` `bootstrap-ansible-user.sh` |

To add an OS, add a record to `BOOTSTRAP_PROVIDERS` in `providers.sh`. More specific matches must appear before broad matches such as `.*`. `shell` providers are run as Bash scripts with `username=... password=...` arguments. `powershell` providers are invoked with `-Username` and `-Password` parameters.

## Requirements

- Bash 4 or newer, OpenSSH client, `timeout`, `sed`, and `base64` is not required.
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
