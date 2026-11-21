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

# add public keys supplied via the comma separated SSH_PUBLIC_KEYS env var (validated and exported
# by init.sh), keys already present in authorized_keys are kept and nothing is ever removed -
# a key dropped from the env var has to be removed from authorized_keys by hand
function add_authorized_keys() {

	local authorized_keys_file="${1}"
	local public_keys="${2}"
	local public_key_list
	local public_key
	local public_key_type

	# create the file if this is the first start, sshd would otherwise see no authorized keys
	touch "${authorized_keys_file}"

	# split comma separated list of public keys, -d '' keeps any embedded newlines so they can be
	# rejected below instead of the tail of the list being silently dropped
	IFS=',' read -d '' -ra public_key_list <<< "${public_keys}" || true

	# process public keys in the list
	for public_key in "${public_key_list[@]}"; do

		# trim leading/trailing whitespace, keys are often pasted across lines
		public_key=$(echo "${public_key}" | sed -e 's~^[[:space:]]*~~;s~[[:space:]]*$~~')

		# skip empty entries, e.g. a trailing comma in the list
		if [[ -z "${public_key}" ]]; then
			continue
		fi

		# a public key is a single line, an embedded newline would inject extra authorized_keys entries
		if [[ "${public_key}" == *$'\n'* ]]; then
			echo "[warn] Ignoring SSH_PUBLIC_KEYS entry containing a newline..."
			continue
		fi

		# only accept a bare public key, authorized_keys options (e.g. 'command=') are not a key
		public_key_type="${public_key%%[[:space:]]*}"
		case "${public_key_type}" in
			ssh-*|ecdsa-sha2-nistp*|sk-*)
				;;
			*)
				echo "[warn] Ignoring SSH_PUBLIC_KEYS entry that is not a public key '${public_key}'..."
				continue
				;;
		esac

		# reject malformed keys, otherwise this entry grants no access and fails silently
		if ! printf '%s\n' "${public_key}" | ssh-keygen -l -f /dev/stdin > /dev/null 2>&1; then
			echo "[warn] Ignoring invalid SSH_PUBLIC_KEYS entry '${public_key}'..."
			continue
		fi

		# append only missing keys, so a container restart does not duplicate every line
		if grep -qxF -- "${public_key}" "${authorized_keys_file}"; then
			continue
		fi

		echo "[info] Adding SSH_PUBLIC_KEYS entry to '${authorized_keys_file}'..."
		printf '%s\n' "${public_key}" >> "${authorized_keys_file}"

	done

	# no keys at all means nobody can log in, fail loudly rather than run an unreachable sshd
	# (blank lines are ignored by sshd, so check for at least one non-blank line)
	if ! grep -q '[^[:space:]]' "${authorized_keys_file}"; then
		echo "[crit] No authorized keys found in '${authorized_keys_file}', set SSH_PUBLIC_KEYS, exiting..."
		exit 1
	fi

}

add_authorized_keys "${authorized_keys}" "${SSH_PUBLIC_KEYS:-}"

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
