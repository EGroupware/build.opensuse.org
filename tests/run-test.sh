#!/bin/bash
# Run an egroupware-docker package test inside a systemd container, with docker-in-docker (amd64, emulated on Apple Silicon)
# Usage: ./run-test.sh <distro> [install]       distro: ubuntu-24.04 ubuntu-26.04 ubuntu-22.04 debian-12 debian-13 rocky-10 rocky-9 opensuse-16.0 opensuse-16.1
# Follow everything (systemd, journal, guest scripts) with: docker logs -f egw-test-<distro>
# Docker Hub images are cached on the host in a pull-through registry mirror (container egw-registry-mirror, volume egw-registry-cache), NO_MIRROR=1 to disable
# Env:   WEBSERVER=apache (default nginx), PLATFORM=linux/amd64|linux/arm64 (default: native platform of the host), KEEP=1 keep machine for inspection (docker exec -it egw-test-<distro> bash), NO_RECOMMENDS=1, EXTRA_PKGS=apache2, TIMEOUT=secs
set -euo pipefail
cd "$(dirname "$0")"
distro=${1:?usage: $0 <distro> [install]}; test=${2:-install}
# native platform of the host by default: arm64 on Apple Silicon (systemd failed under amd64 emulation there), amd64 on x86 hosts and CI
case "$(uname -m)" in aarch64|arm64) native=linux/arm64 ;; *) native=linux/amd64 ;; esac
PLATFORM=${PLATFORM:-$native}
case $distro in
	ubuntu-*) base=ubuntu:${distro#ubuntu-}; obs=xUbuntu_${distro#ubuntu-}; family=deb ;;
	debian-*) base=debian:${distro#debian-}; obs=Debian_${distro#debian-};  family=deb ;;
	opensuse-*) base=opensuse/leap:${distro#opensuse-}; obs=openSUSE_Leap_${distro#opensuse-}; family=zypper ;;
	rocky-*)  base=rockylinux/rockylinux:${distro#rocky-}; obs=RockyLinux_${distro#rocky-}; family=rpm ;;
	*) echo "unsupported distro $distro " >&2; exit 2 ;;
esac
# WEBSERVER=apache: new installation with Apache instead of the preferred Nginx, by adding apache2 (Debian/Ubuntu) or httpd (RHEL) to the install command, as per wiki
web=${WEBSERVER:-nginx}; suffix=""
case $web in
	nginx) ;;
	apache) suffix=-apache; EXTRA_PKGS="${EXTRA_PKGS:+$EXTRA_PKGS }$([ $family = rpm ] && echo httpd || echo apache2)" ;;
	*) echo "unknown WEBSERVER $web (nginx or apache)" >&2; exit 2 ;;
esac
# every machine has its own docker+containerd volumes with all images (several GB): do not fill up the disk of the host (happened once)
# (macOS: the data volume, elsewhere eg. the CI runner: the filesystem of /var/lib/docker or /)
disk=/System/Volumes/Data; [ -d $disk ] || { disk=/var/lib/docker; [ -d $disk ] || disk=/; }
avail_gb=$(df -Pk $disk 2>/dev/null | awk 'NR==2{print int($4/1024/1024)}' || true)
[ -z "$avail_gb" ] || [ "$avail_gb" -ge ${MIN_FREE_GB:-20} ] || { echo "only ${avail_gb}GB free on the host disk, need ${MIN_FREE_GB:-20}GB (MIN_FREE_GB=...), aborting" >&2; exit 3; }
# ROCKETCHAT=1: also install egroupware-rocketchat with its OAuth integration into EGroupware, using an own CA for the hostname egw.test (guest/tls.sh), needs Nginx
# RC_OVERLAY=dir: files of a not yet released version of the package (docker-compose.yml, install-rocketchat.sh, ...) to test instead of the published ones
rc=${ROCKETCHAT:-}
if [ -n "$rc" ]; then
	[ $web = nginx ] || { echo "ROCKETCHAT=1 needs the default WEBSERVER=nginx" >&2; exit 2; }
	suffix="$suffix-rocketchat"
fi
# GUACAMOLE=1: also install egroupware-guacamole, which logs in via OpenID Connect against EGroupware, using an own CA like ROCKETCHAT=1, needs Nginx
gc=${GUACAMOLE:-}
if [ -n "$gc" ]; then
	[ $web = nginx ] || { echo "GUACAMOLE=1 needs the default WEBSERVER=nginx" >&2; exit 2; }
	[ -z "$rc" ] || { echo "ROCKETCHAT=1 and GUACAMOLE=1 can not be combined" >&2; exit 2; }
	suffix="$suffix-guacamole"
fi
# MAIL=1: also install egroupware-mail (Dovecot and Postfix containers), plain http is enough, no own CA needed
ml=${MAIL:-}
if [ -n "$ml" ]; then
	[ -z "$rc$gc" ] || { echo "MAIL=1 can not be combined with ROCKETCHAT=1 or GUACAMOLE=1" >&2; exit 2; }
	suffix="$suffix-mail"
fi
# SMB=1: also start a Samba server and test SMB access from the egroupware container (smb:// via PHP, mounted into the VFS with filemanager/cli.php, short server names via search domain)
smb=${SMB:-}
[ -z "$smb" ] || { [ -z "$rc$gc$ml" ] || { echo "SMB=1 can not be combined with ROCKETCHAT=1, GUACAMOLE=1 or MAIL=1" >&2; exit 2; }; suffix="$suffix-smb"; }
# MAIL_PKG=file: install this (noarch .rpm) package file instead of the published egroupware-mail
mail_pkg=${MAIL_PKG:-}
[ -z "$mail_pkg" ] || [ -n "$ml" ] || { echo "MAIL_PKG needs MAIL=1" >&2; exit 2; }
name=egw-test-$distro$suffix
image=egw-test-base:$distro
cleanup() { [ -n "${KEEP:-}" ] && { echo "kept: docker exec -it $name bash"; return; }; docker rm -f $name >/dev/null 2>&1; docker volume rm -f $name-docker $name-containerd >/dev/null 2>&1; }
trap cleanup EXIT
docker rm -f $name >/dev/null 2>&1 || true; docker volume rm -f $name-docker $name-containerd >/dev/null 2>&1 || true

# pull-through cache for Docker Hub: the inner docker pulls via this mirror, so every run is still a clean install, just with fast pulls
net=""
if [ -z "${NO_MIRROR:-}" ]; then
	docker network inspect egw-test-net >/dev/null 2>&1 || docker network create egw-test-net >/dev/null
	docker inspect -f '{{.State.Running}}' egw-registry-mirror 2>/dev/null | grep -q true || {
		docker rm -f egw-registry-mirror >/dev/null 2>&1 || true
		docker run -d --name egw-registry-mirror --network egw-test-net --restart unless-stopped \
			-v egw-registry-cache:/var/lib/registry -e REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io registry:2 >/dev/null
	}
	net="--network egw-test-net"
fi

docker build --platform $PLATFORM -f Dockerfile.$family --build-arg BASE=$base -t $image .
docker run -d -t --platform $PLATFORM --name $name --hostname $name --privileged --cgroupns=host $net \
	--tmpfs /run --tmpfs /run/lock --tmpfs /tmp -v $name-docker:/var/lib/docker -v $name-containerd:/var/lib/containerd $image >/dev/null
for i in $(seq 60); do
	s=$(docker exec $name systemctl is-system-running 2>/dev/null || true)
	[ "$s" = running -o "$s" = degraded ] && break; sleep 2
done
echo "systemd: $s"
docker cp guest $name:/opt/guest
# tell the docker, the package will install, about the mirror (daemon.json is not owned by the docker packages)
[ -z "$net" ] || docker exec $name bash -c 'mkdir -p /etc/docker && echo "{\"registry-mirrors\":[\"http://egw-registry-mirror:5000\"],\"insecure-registries\":[\"egw-registry-mirror:5000\"]}" > /etc/docker/daemon.json'
web_base=http://localhost
[ $family = rpm -a $web = apache ] && web_base=https://localhost
[ -z "$rc$gc" ] || web_base=https://egw.test
env_args=(-e OBS_DIST=$obs -e NO_RECOMMENDS=${NO_RECOMMENDS:-} -e EXTRA_PKGS=${EXTRA_PKGS:-} -e TIMEOUT=${TIMEOUT:-1800} -e WEB_BASE=$web_base -e EXPECT_WEBSERVER=$web -e EXPECT_COLLABORA=$([ -n "${NO_RECOMMENDS:-}" ] && echo 0 || echo 1) -e TLS_HOST=egw.test -e TLS_TRUSTED=$rc$gc -e EXPECT_ROCKETCHAT=$([ -n "$rc" ] && echo 1 || echo 0) -e EXPECT_GUACAMOLE=$([ -n "$gc" ] && echo 1 || echo 0) -e EXPECT_MAIL=$([ -n "$ml" ] && echo 1 || echo 0) -e EXPECT_SMB=$([ -n "$smb" ] && echo 1 || echo 0))
# run a setup step of the guest in its own process group, killed with all its children after SETUP_TIMEOUT seconds (a hanging "docker compose logs -f" would
# otherwise keep the job running until the CI timeout), diagnostics (containers and their logs) on failure
guest_step() {   # label script [docker exec options]
	local label=$1 script=$2; shift 2
	docker exec "${env_args[@]}" "$@" $name bash -c "
		set -o pipefail
		setsid bash /opt/guest/$script > >(tee /dev/console) 2>&1 & p=\$!
		( sleep ${SETUP_TIMEOUT:-1500}; echo 'TIMEOUT: killing the setup step' >/dev/console; kill -KILL -- -\$p 2>/dev/null ) & wd=\$!
		wait \$p; rc=\$?; kill \$wd 2>/dev/null; exit \$rc" \
		|| { echo "WARNING: the $label setup failed or timed out, the checks will tell more"; docker exec $name bash /opt/guest/diag.sh 2>&1 | tee /dev/console; }
}
case $test in
	install) docker exec "${env_args[@]}" $name bash -c "set -o pipefail; bash /opt/guest/install-$family.sh 2>&1 | tee /dev/console" ;;
	*) echo "unknown test $test" >&2; exit 2 ;;
esac
# MongoDB 8 refuses to start on Linux 6.19 to 7.0.13 (bug in its TCMalloc, fixed with kernel 7.0.14), the containers share the kernel of the host,
# which varies on CI runners and is 7.0.x on Ubuntu 26.04: Rocket.Chat can not run then, that is no package problem
if [ -n "$rc" ]; then
	kernel=$(docker exec $name uname -r | sed 's/[^0-9.].*//')
	if [ "$(printf '6.19\n%s\n' "$kernel" | sort -V | head -1)" = 6.19 ] && [ "$(printf '7.0.14\n%s\n' "$kernel" | sort -V | head -1)" != 7.0.14 ]; then
		echo "SKIP: Rocket.Chat, MongoDB 8 can not start on this kernel ($(docker exec $name uname -r)), it needs < 6.19 or >= 7.0.14 (https://jira.mongodb.org/browse/SERVER-121912)"
		rc=""
		# the checks of the plain installation: no own CA, http://localhost
		env_args=("${env_args[@]/EXPECT_ROCKETCHAT=1/EXPECT_ROCKETCHAT=0}")
		env_args=("${env_args[@]/WEB_BASE=https:\/\/egw.test/WEB_BASE=$([ $family = rpm -a $web = apache ] && echo https://localhost || echo http://localhost)}")
		env_args=("${env_args[@]/TLS_TRUSTED=1/TLS_TRUSTED=}")
	fi
fi
if [ -n "$rc" ]; then
	rc_env=()
	if [ -n "${RC_OVERLAY:-}" ]; then
		tmp=$(mktemp -d); cp -R "$RC_OVERLAY"/. "$tmp"/; docker cp "$tmp"/. $name:/opt/rc-overlay; rm -rf "$tmp"
		rc_env=(-e RC_OVERLAY=/opt/rc-overlay)
	fi
	guest_step Rocket.Chat rocketchat.sh ${rc_env[@]+"${rc_env[@]}"}
fi
if [ -n "$gc" ]; then
	guest_step Guacamole guacamole.sh
fi
if [ -n "$ml" ]; then
	[ -z "$mail_pkg" ] || { docker exec $name mkdir -p /opt/mail-pkg; docker cp "$mail_pkg" $name:/opt/mail-pkg/; }
	guest_step mail mail.sh
fi
if [ -n "$smb" ]; then
	guest_step SMB smb.sh
fi
docker exec "${env_args[@]}" $name bash -c "bash /opt/guest/verify.sh 2>&1 | tee /dev/console; exit \${PIPESTATUS[0]}"
