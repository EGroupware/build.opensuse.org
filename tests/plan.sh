#!/bin/bash
# Plan of a package-tests run: which distros to test, which packages the commit changed and which OBS repos to wait for.
# Prints key=value lines (suitable for $GITHUB_OUTPUT):
#   distros=<json list>   distros to test
#   pkgargs=<args>        --pkg PACKAGE=SRCMD5 ... for wait-for-obs.py, empty if there is nothing to wait for
#   repos=<args>          --repo OBS_REPO ... for wait-for-obs.py
# Env: EVENT (push or workflow_dispatch), BEFORE, SHA (of the push), INPUT_DISTRO (default, all or a single distro)
set -euo pipefail

# permanently tested on every commit: the 2 latest Debian and Ubuntu releases, only the latest of everything else
DEFAULT=(ubuntu-26.04 ubuntu-24.04 debian-13 debian-12 rocky-10 opensuse-16.1)
# everything the harness supports and we have packages for, can be selected for manual runs
ALL=(rocky-10 rocky-9 ubuntu-26.04 ubuntu-24.04 ubuntu-22.04 debian-13 debian-12 opensuse-16.1 opensuse-16.0)
# packages with install tests: directory in this repo = OBS package
DIR=server:eGroupWare
PKGS=(egroupware-docker-26 egroupware-collabora-key)

obs_repo() {
	case $1 in
		ubuntu-*)   echo "xUbuntu_${1#ubuntu-}" ;;
		debian-*)   echo "Debian_${1#debian-}" ;;
		rocky-*)    echo "RockyLinux_${1#rocky-}" ;;
		opensuse-*) echo "openSUSE_Leap_${1#opensuse-}" ;;
		*) echo "unknown distro $1" >&2; return 1 ;;
	esac
}

sel=${INPUT_DISTRO:-default}
case $sel in
	default|'') distros=("${DEFAULT[@]}") ;;
	all)        distros=("${ALL[@]}") ;;
	*)  [[ " ${ALL[*]} " == *" $sel "* ]] || { echo "unsupported distro '$sel', supported: ${ALL[*]}" >&2; exit 1; }
	    distros=("$sel") ;;
esac
json=$(printf '"%s",' "${distros[@]}"); echo "distros=[${json%,}]"

# only commits (pushes) wait for OBS, a manual run tests what is currently published
pkgargs=""; repos=""
if [ "${EVENT:-}" = push ]; then
	changed=""
	if [ -n "${BEFORE:-}" ] && [ -n "${BEFORE//0/}" ]; then
		changed=$(gh api "repos/${GITHUB_REPOSITORY:-none}/compare/${BEFORE}...${SHA:-HEAD}" --paginate --jq '.files[].filename' 2>/dev/null \
			|| git diff --name-only "$BEFORE" "${SHA:-HEAD}" 2>/dev/null || true)
	fi
	# unknown what changed (new branch, force push): wait for all packages
	[ -n "$changed" ] || changed=$(printf "$DIR/%s/\n" "${PKGS[@]}")
	for pkg in "${PKGS[@]}"; do
		echo "$changed" | grep -q "^$DIR/$pkg/" || continue
		md5=$(grep -o 'srcmd5="[0-9a-f]*"' "$DIR/$pkg/.osc/_files" 2>/dev/null | head -1 | cut -d'"' -f2 || true)
		if [ -n "$md5" ]; then pkgargs="$pkgargs --pkg $pkg=$md5"
		else echo "WARNING: no srcmd5 in $DIR/$pkg/.osc/_files, not waiting for $pkg (commit after osc commit!)" >&2; fi
	done
	for d in "${distros[@]}"; do repos="$repos --repo $(obs_repo "$d")"; done
fi
echo "pkgargs=${pkgargs# }"
echo "repos=${repos# }"
