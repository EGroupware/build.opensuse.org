#!/bin/bash
# Clean new installation on Rocky Linux / RHEL 9+, based on the wiki:
# https://github.com/EGroupware/egroupware/wiki/Distribution-specific-instructions ("RHEL or CentOS 8 / Rocky Linux 8", no Rocky 9/10 section yet)
# https://github.com/EGroupware/egroupware/wiki/Installation-using-EGroupware-docker-RPM-DEB-package
# Runs as root inside the test machine, so no sudo.
# Env: OBS_DIST (eg. RockyLinux_10), EXTRA_PKGS
set -euxo pipefail
: "${OBS_DIST:?}"
# plain line-by-line docker compose progress in test logs, instead of animated bars (only here, not in the package)
export COMPOSE_PROGRESS=plain
OBS_KEY=${OBS_KEY_REPO:-https://download.opensuse.org/repositories/server:eGroupWare}

# 1. docker is NOT installed by the package on RHEL: add Docker CE repo, install docker-ce and the compose plugin, enable and start it
curl -fsSL https://download.docker.com/linux/centos/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo
dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

# 2. add the EGroupware repo
curl -fsSL -o /etc/yum.repos.d/server:eGroupWare.repo "$OBS_KEY/$OBS_DIST/server:eGroupWare.repo"

# 3. install, wiki: "yum install egroupware-docker egroupware-collabora-key" (NO_RECOMMENDS=1 skips collabora-key)
PKGS="egroupware-docker"; [ -n "${NO_RECOMMENDS:-}" ] || PKGS="$PKGS egroupware-collabora-key"
dnf -y install $PKGS ${EXTRA_PKGS:-}
