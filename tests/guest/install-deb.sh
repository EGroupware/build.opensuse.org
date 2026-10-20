#!/bin/bash
# Clean new installation on Debian/Ubuntu, mirrors the wiki:
# https://github.com/EGroupware/egroupware/wiki/Installation-using-EGroupware-docker-RPM-DEB-package
# https://github.com/EGroupware/egroupware/wiki/Distribution-specific-instructions
# Runs as root inside the test machine, so no sudo.
# Env: OBS_DIST (eg. xUbuntu_24.04 or Debian_13), NO_RECOMMENDS=1 to skip Collabora key (wiki: "opt out"), EXTRA_PKGS (eg. apache2)
set -euxo pipefail
: "${OBS_DIST:?}"
# plain line-by-line docker compose progress in test logs, instead of animated bars (only here, not in the package, as admins like those)
export COMPOSE_PROGRESS=plain
OBS=${OBS_REPO:-http://download.opensuse.org/repositories/server:/eGroupWare}
OBS_KEY=${OBS_KEY_REPO:-https://download.opensuse.org/repositories/server:eGroupWare}

# 1. add repo and key
echo "deb $OBS/$OBS_DIST/ /" | tee /etc/apt/sources.list.d/server:eGroupWare.list
apt-get install -y gnupg
wget -nv "$OBS_KEY/$OBS_DIST/Release.key" -O - | tee /etc/apt/trusted.gpg.d/server:eGroupWare.asc
apt-get update

# 2. install, wiki: "apt install egroupware-docker" (add apache2 to use Apache instead of Nginx)
OPTS=""; [ -z "${NO_RECOMMENDS:-}" ] || OPTS="--no-install-recommends"
apt-get install -y $OPTS egroupware-docker ${EXTRA_PKGS:-}
