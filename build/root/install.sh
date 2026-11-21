#!/bin/bash

# exit script if return code != 0
set -e

# app name from buildx arg, used in healthcheck to identify app and monitor correct process
APPNAME="${1}"
shift

# release tag name from buildx arg, stripped of build ver using string manipulation
RELEASETAG="${1}"
shift

# target arch from buildx arg
TARGETARCH="${1}"
shift

if [[ -z "${APPNAME}" ]]; then
	echo "[warn] App name from build arg is empty, exiting script..."
	exit 1
fi

if [[ -z "${RELEASETAG}" ]]; then
	echo "[warn] Release tag name from build arg is empty, exiting script..."
	exit 1
fi

if [[ -z "${TARGETARCH}" ]]; then
	echo "[warn] Target architecture name from build arg is empty, exiting script..."
	exit 1
fi

# write APPNAME and RELEASETAG to file to record the app name and release tag used to build the image
echo -e "export APPNAME=${APPNAME}\nexport IMAGE_RELEASE_TAG=${RELEASETAG}\n" >> '/etc/image-build-info'

# ensure we have the latest builds scripts
refresh.sh

# pacman packages
####

# define pacman packages
pacman_packages="openssh"

# install compiled packages using pacman
if [[ -n "${pacman_packages}" ]]; then
	# arm64 currently targetting aor not archive, so we need to update the system first
	if [[ "${TARGETARCH}" == "arm64" ]]; then
		pacman -Syu --noconfirm
	fi
	pacman -S --needed $pacman_packages --noconfirm
fi

# custom
####

# create ssh config file to only allow key based auth, disable root login, and set the authorized keys file for the nobody user
# host keys are NOT generated here, they are created per deployment on first start by start.sh
# and stored in the /config bind mount, otherwise every container built from this image shares the same host identity
cat <<'EOF' > /etc/ssh/sshd_config.d/10-keys-only.conf
Port 22
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitRootLogin no
AllowUsers nobody
# this image runs sshd as 'nobody' and chmods /config to 0775 with umask 000, which sshd's
# StrictModes rejects as 'bad ownership or modes' - start.sh tightens the key file modes instead
StrictModes no
UsePAM yes
# sshd runs as 'nobody' and cannot write /run, the pid is not needed under supervisor
PidFile none
HostKey /config/herdr-core/ssh/host_keys/ssh_host_ed25519_key
AuthorizedKeysFile /config/herdr-core/ssh/keys/authorized_keys
EOF

# install herdr-core
curl -fsSL https://releases.herdr.dev/core/install.sh | sh

# container perms
####

# define comma separated list of paths, these are chowned to PUID/PGID on container start
# (injected into init.sh as install_paths) and chmod 775 during build.
# NOTE: this list is intentionally empty, /etc/ssh MUST NOT be added - a recursive chmod
# leaves the sshd host keys group/world readable, and sshd then refuses to start with
# 'no hostkeys available -- exiting'. /config ownership is already handled by init.sh.
install_paths="/home/nobody"

if [[ -n "${install_paths}" ]]; then

	# split comma separated string into list for install paths
	IFS=',' read -ra install_paths_list <<< "${install_paths}"

	# process install paths in the list
	for i in "${install_paths_list[@]}"; do

		# confirm path(s) exist, if not then exit
		if [[ ! -d "${i}" ]]; then
			echo "[crit] Path '${i}' does not exist, exiting build process..." ; exit 1
		fi

	done

	# convert comma separated string of install paths to space separated, required for chmod/chown processing
	install_paths=$(echo "${install_paths}" | tr ',' ' ')

	# set permissions for container during build - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
	# shellcheck disable=SC2086
	chmod -R 775 ${install_paths}

fi

cat <<'EOF' > /tmp/config_heredoc

# call symlink function from utils.sh
symlink --src-path '/config/home' --dst-path '/home/nobody' --link-type 'softlink'
EOF

# replace config placeholder string with contents of file (here doc)
sed -i '/# CONFIG_PLACEHOLDER/{
    s/# CONFIG_PLACEHOLDER//g
    r /tmp/config_heredoc
}' /usr/bin/init.sh
rm /tmp/config_heredoc

# In install.sh heredoc, replace the chown section:
cat <<EOF > /tmp/permissions_heredoc
install_paths="${install_paths}"
EOF

# replace permissions placeholder string with contents of file (here doc)
sed -i '/# PERMISSIONS_PLACEHOLDER/{
    s/# PERMISSIONS_PLACEHOLDER//g
    r /tmp/permissions_heredoc
}' /usr/bin/init.sh
rm /tmp/permissions_heredoc

# env vars
####

cat <<'EOF' > /tmp/envvars_heredoc

# source in utility functions, need process_env_var
source utils.sh

# Define environment variables to process
# Format: "VAR_NAME:DEFAULT_VALUE:REQUIRED:MASK"
env_vars=(
	"SSH_PUBLIC_KEYS::true:false"
	"ENABLE_STARTUP_SCRIPTS:no:false:false"
	"STARTUP_SCRIPTS_MODE:wait:false:false"
)

# Process each environment variable
for env_var in "${env_vars[@]}"; do
	IFS=':' read -r var_name default_value required mask_value <<< "${env_var}"
	process_env_var "${var_name}" "${default_value}" "${required}" "${mask_value}"
done
EOF

# replace env vars placeholder string with contents of file (here doc)
sed -i '/# ENVVARS_PLACEHOLDER/{
    s/# ENVVARS_PLACEHOLDER//g
    r /tmp/envvars_heredoc
}' /usr/bin/init.sh
rm /tmp/envvars_heredoc

# cleanup
cleanup.sh
