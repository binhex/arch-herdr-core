#!/usr/bin/dumb-init /bin/bash
# shellcheck shell=bash

set -euo pipefail

# no config bind mount
if [[ ! -d "/config" ]]; then
	echo "[crit] /config bind mount not found, exiting..." ; exit 1
fi

# paths kept inside the /config bind mount so they survive container recreation
ssh_dir="/config/herdr-core/ssh"
logs_dir="${ssh_dir}/logs"
keys_dir="${ssh_dir}/keys"
host_keys_dir="${ssh_dir}/host_keys"
authorized_keys="${keys_dir}/authorized_keys"

mkdir -p "${logs_dir}" "${keys_dir}" "${host_keys_dir}"

# copy public keygen
if [[ ! -f "${authorized_keys}" ]]; then
  echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEKoGSJbfQ698s2nK08RYPPzMOecNjAJJ9TR5fRwgpm5' >> "${authorized_keys}"
fi

# generate the host key once per deployment, generating it at build time would give every
# container built from this image the same host identity
if [[ ! -f "${host_keys_dir}/ssh_host_ed25519_key" ]]; then
	echo "[info] Generating ssh host key '${host_keys_dir}/ssh_host_ed25519_key'..."
	ssh-keygen -q -t ed25519 -N "" -C "herdr-core" -f "${host_keys_dir}/ssh_host_ed25519_key"
fi

# init.sh sets /config to 0775 and supervisor uses umask 000, so tighten the key material
chmod 700 "${ssh_dir}"
chmod 600 "${authorized_keys}"
chmod 600 "${host_keys_dir}"/ssh_host_*_key
chmod 644 "${host_keys_dir}"/*.pub

# run openssh
echo "[info] Running OpenSSH server..."
exec /usr/sbin/sshd -D -e >>"${logs_dir}/sshd.log" 2>&1
