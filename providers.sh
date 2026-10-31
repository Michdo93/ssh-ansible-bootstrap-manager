#!/usr/bin/env bash
# Provider record format: id|OS_ID_regex|execution_type|bootstrap_URL
#
#   OS_ID_regex     matched (anchored) against ID= from /etc/os-release, or "windows";
#                   use [] / () for alternatives, never a pipe character
#   execution_type  shell (bash script, Linux) | powershell (Windows)
#   bootstrap_URL   raw GitHub URL or file:///absolute/path
#
# The script is uploaded from the control node; targets do not need curl.
# If a checkout of the provider repository exists next to this repository
# (../ansible-linux-bootstrap/...), in ./vendor/ or in $BOOTSTRAP_PROVIDER_DIR,
# that local, reviewed copy is used instead of downloading the URL.
# The first matching record wins, so keep the catch-all Linux record last.
# shellcheck disable=SC2034
BOOTSTRAP_PROVIDERS=(
  'windows|windows|powershell|https://raw.githubusercontent.com/Michdo93/ansible-windows-bootstrap/main/bootstrap.ps1'
  'kali|kali|shell|https://raw.githubusercontent.com/Michdo93/ansible-kali-bootstrap/main/bootstrap-ansible-user.sh'
  'linux|.*|shell|https://raw.githubusercontent.com/Michdo93/ansible-linux-bootstrap/main/bootstrap-ansible-user.sh'
)
