#!/usr/bin/env bash
# Provider record format: id|OS_ID_regex|execution_type|bootstrap_URL
# Add records here to support more distributions or bootstrap entry points.
BOOTSTRAP_PROVIDERS=(
  'windows|windows|powershell|https://raw.githubusercontent.com/Michdo93/ansible-windows-bootstrap/main/bootstrap.ps1'
  'kali|kali|shell|https://raw.githubusercontent.com/Michdo93/ansible-kali-bootstrap/main/bootstrap-ansible-user.sh'
  'linux|.*|shell|https://raw.githubusercontent.com/Michdo93/ansible-linux-bootstrap/main/bootstrap-ansible-user.sh'
)
