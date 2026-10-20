#!/bin/bash
# Clean new installation on openSUSE Leap, as per wiki:
# https://github.com/EGroupware/egroupware/wiki/Distribution-specific-instructions ("openSUSE 15.x or SLES": zypper addrepo, zypper refresh, zypper install egroupware-docker)
# Runs as root inside the test machine, so no sudo.
# Env: OBS_DIST (eg. openSUSE_Leap_16.0), NO_RECOMMENDS=1 for --no-recommends (wiki: "opt out"), EXTRA_PKGS (eg. apache2)
set -euxo pipefail
: "${OBS_DIST:?}"
# plain line-by-line docker compose progress in test logs, instead of animated bars (only here, not in the package)
export COMPOSE_PROGRESS=plain
OBS_KEY=${OBS_KEY_REPO:-https://download.opensuse.org/repositories/server:eGroupWare}

# 1. add the EGroupware repo and refresh (-n and --gpg-auto-import-keys instead of answering the prompts)
zypper -n addrepo -f "$OBS_KEY/$OBS_DIST/server:eGroupWare.repo"
zypper -n --gpg-auto-import-keys refresh

# 2. install, wiki: "zypper install egroupware-docker"
# container images set solver.onlyRequires=true, a real server installs recommended packages (egroupware-collabora-key) by default
OPTS="--recommends"; [ -z "${NO_RECOMMENDS:-}" ] || OPTS="--no-recommends"
zypper -n install $OPTS egroupware-docker ${EXTRA_PKGS:-}
