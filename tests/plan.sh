#!/bin/bash
# Plan of a package-tests run: which jobs to run, which packages the commit changed and which OBS repos to wait for.
# Prints key=value lines (suitable for $GITHUB_OUTPUT):
#   matrix=<json>         job matrix {"include":[{"distro":..,"webserver":..,"kind":..}, ...]}, kind is base, rocketchat, guacamole, mail or smb
#   pkgargs=<args>        --pkg PACKAGE=SRCMD5[:REPO,REPO] ... for wait-for-obs.py, empty if there is nothing to wait for
#   repos=<args>          --repo OBS_REPO ... for wait-for-obs.py
# Env: EVENT (push or workflow_dispatch), BEFORE, SHA (of the push),
#      INPUT_DISTRO (default, all or a single distro), INPUT_TEST (install, rocketchat, guacamole, mail, smb or all) for manual runs
set -euo pipefail

# permanently tested on every commit: the 2 latest Debian and Ubuntu releases, only the latest of everything else
DEFAULT=(ubuntu-26.04 ubuntu-24.04 debian-13 debian-12 rocky-10 opensuse-16.1)
# everything the harness supports and we have packages for, can be selected for manual runs
ALL=(rocky-10 rocky-9 ubuntu-26.04 ubuntu-24.04 ubuntu-22.04 debian-13 debian-12 opensuse-16.1 opensuse-16.0)
# packages with install tests: directory in this repo = OBS package, and the kind of test
DIR=server:eGroupWare
# base:        egroupware-docker-26 and Collabora with Nginx and Apache
# rocketchat:  egroupware-rocketchat with OAuth integration into EGroupware (Nginx, own CA, see guest/tls.sh)
# guacamole:   egroupware-guacamole with OpenID login via EGroupware (Nginx, own CA)
# mail:        egroupware-mail (Dovecot and Postfix), Debian, Ubuntu and Rocky 10 (no SUSE package yet)
# smb:         SMB/CIFS access from the egroupware container to a Samba server (smb:// in PHP, mounted into the VFS, short server names), needs the
#              egroupware image only, not the distro, so it runs on one distro and is run with every change of egroupware-docker-26
kind_of() {
	case $1 in
		egroupware-docker-26|egroupware-collabora-key) echo base ;;
		egroupware-rocketchat) echo rocketchat ;;
		egroupware-guacamole) echo guacamole ;;
		egroupware-mail) echo mail ;;
	esac
}
PKGS=(egroupware-docker-26 egroupware-collabora-key egroupware-rocketchat egroupware-guacamole egroupware-mail)
KINDS=(base rocketchat guacamole mail smb)

obs_repo() {
	case $1 in
		ubuntu-*)   echo "xUbuntu_${1#ubuntu-}" ;;
		debian-*)   echo "Debian_${1#debian-}" ;;
		rocky-*)    echo "RockyLinux_${1#rocky-}" ;;
		opensuse-*) echo "openSUSE_Leap_${1#opensuse-}" ;;
		*) echo "unknown distro $1" >&2; return 1 ;;
	esac
}

# does the test of this kind run on the distro?
# the https tests (own CA, tls.sh) need Nginx, which is not the default of the SUSE package (Requires: httpd), they are not supported there yet
applies() {   # kind distro
	case $1 in
		base) return 0 ;;
		rocketchat|guacamole) case $2 in opensuse-*) return 1 ;; *) return 0 ;; esac ;;
		mail) case $2 in ubuntu-*|debian-*|rocky-10) return 0 ;; *) return 1 ;; esac ;;
		smb) [ "$2" = debian-13 ] ;;
	esac
}

sel=${INPUT_DISTRO:-default}
case $sel in
	default|'') distros=("${DEFAULT[@]}") ;;
	all)        distros=("${ALL[@]}") ;;
	*)  [[ " ${ALL[*]} " == *" $sel "* ]] || { echo "unsupported distro '$sel', supported: ${ALL[*]}" >&2; exit 1; }
	    distros=("$sel") ;;
esac

run=" "              # kinds to run, space separated
pkgargs=""; repos=""
if [ "${EVENT:-}" = push ]; then
	# which of the packages did the commit change?
	changed=""
	if [ -n "${BEFORE:-}" ] && [ -n "${BEFORE//0/}" ]; then
		changed=$(gh api "repos/${GITHUB_REPOSITORY:-none}/compare/${BEFORE}...${SHA:-HEAD}" --paginate --jq '.files[].filename' 2>/dev/null \
			|| git diff --name-only "$BEFORE" "${SHA:-HEAD}" 2>/dev/null || true)
	fi
	# unknown what changed (new branch, force push): all packages
	[ -n "$changed" ] || changed=$(printf "$DIR/%s/\n" "${PKGS[@]}")
	# only commits (pushes) wait for OBS, the build of the commit is identified by the source md5 of the package directory
	for pkg in "${PKGS[@]}"; do
		echo "$changed" | grep -q "^$DIR/$pkg/" || continue
		kind=$(kind_of "$pkg"); run="$run$kind "
		# the SMB test runs with the egroupware image installed by egroupware-docker-26
		[ "$pkg" != egroupware-docker-26 ] || run="${run}smb "
		md5=$(grep -o 'srcmd5="[0-9a-f]*"' "$DIR/$pkg/.osc/_files" 2>/dev/null | head -1 | cut -d'"' -f2 || true)
		if [ -z "$md5" ]; then echo "WARNING: no srcmd5 in $DIR/$pkg/.osc/_files, not waiting for $pkg (commit after osc commit!)" >&2; continue; fi
		# only the repositories of the distros the test of this package runs on
		only=""
		for d in "${distros[@]}"; do applies "$kind" "$d" && only="$only,$(obs_repo "$d")"; done
		pkgargs="$pkgargs --pkg $pkg=$md5${only:+:${only#,}}"
	done
	for d in "${distros[@]}"; do repos="$repos --repo $(obs_repo "$d")"; done
else
	# manual run: tests what is currently published
	case ${INPUT_TEST:-install} in
		install)    run=" base " ;;
		rocketchat) run=" rocketchat " ;;
		guacamole)  run=" guacamole " ;;
		mail)       run=" mail " ;;
		smb)        run=" smb " ;;
		all)        run=" ${KINDS[*]} " ;;
		*) echo "unknown test '${INPUT_TEST:-}', supported: install, rocketchat, guacamole, mail, smb, all" >&2; exit 1 ;;
	esac
fi

# the jobs: every distro with Nginx and Apache for the base packages, the others with Nginx and their own option (ROCKETCHAT=1, GUACAMOLE=1, MAIL=1)
jobs=""
for d in "${distros[@]}"; do
	for k in "${KINDS[@]}"; do
		[[ "$run" == *" $k "* ]] && applies "$k" "$d" || continue
		if [ $k = base ]; then
			jobs="$jobs{\"distro\":\"$d\",\"webserver\":\"nginx\",\"kind\":\"base\"},{\"distro\":\"$d\",\"webserver\":\"apache\",\"kind\":\"base\"},"
		else
			jobs="$jobs{\"distro\":\"$d\",\"webserver\":\"nginx\",\"kind\":\"$k\"},"
		fi
	done
done
echo "matrix={\"include\":[${jobs%,}]}"
echo "pkgargs=${pkgargs# }"
echo "repos=${repos# }"
