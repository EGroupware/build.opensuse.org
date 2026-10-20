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
avail_gb=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print int($4/1024/1024)}')
[ -z "$avail_gb" ] || [ "$avail_gb" -ge ${MIN_FREE_GB:-20} ] || { echo "only ${avail_gb}GB free on the host disk, need ${MIN_FREE_GB:-20}GB (MIN_FREE_GB=...), aborting" >&2; exit 3; }
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
env_args=(-e OBS_DIST=$obs -e NO_RECOMMENDS=${NO_RECOMMENDS:-} -e EXTRA_PKGS=${EXTRA_PKGS:-} -e TIMEOUT=${TIMEOUT:-1800} -e WEB_BASE=$([ $family = rpm -a $web = apache ] && echo https://localhost || echo http://localhost) -e EXPECT_WEBSERVER=$web -e EXPECT_COLLABORA=$([ -n "${NO_RECOMMENDS:-}" ] && echo 0 || echo 1))
case $test in
	install) docker exec "${env_args[@]}" $name bash -c "set -o pipefail; bash /opt/guest/install-$family.sh 2>&1 | tee /dev/console" ;;
	*) echo "unknown test $test" >&2; exit 2 ;;
esac
docker exec "${env_args[@]}" $name bash -c "bash /opt/guest/verify.sh 2>&1 | tee /dev/console; exit \${PIPESTATUS[0]}"
