#!/bin/bash
# Install egroupware-mail (Dovecot + Postfix containers, integrated into EGroupware) after the egroupware-docker install,
# runs as root inside the test machine, the checks are in verify-mail.sh
# The package is only built for amd64 (the Dovecot image has no other platform). On an arm64 host (Apple Silicon) it can not be installed
# normally, so the amd64 package is forced onto the arm64 machine and the containers run emulated (DOCKER_DEFAULT_PLATFORM): this tests
# package contents and scripts, but not the amd64 distro dependencies, that is what the CI on an x86 host is for.
set -euxo pipefail
export COMPOSE_PROGRESS=plain
if command -v apt-get >/dev/null; then INSTALL="apt-get install -y"
elif command -v dnf >/dev/null; then INSTALL="dnf -y install"
else INSTALL="zypper -n install"; fi
# curl-minimal / libcurl-minimal of the RHEL distros do not speak imaps and smtp, which the checks use (libcurl-full replaces libcurl-minimal)
[ "$INSTALL" != "dnf -y install" ] || dnf -y install --allowerasing curl libcurl-full
# on a host that can not run the amd64 images natively, they run emulated
[ "$(uname -m)" = x86_64 ] || export DOCKER_DEFAULT_PLATFORM=linux/amd64
if ls /opt/mail-pkg/* >/dev/null 2>&1; then
	# a not yet published package file (MAIL_PKG of run-test.sh), noarch RPMs install on any architecture
	$INSTALL /opt/mail-pkg/*
else
# the RPM is noarch, only the Debian package is amd64 and has to be forced onto other architectures
case "$(uname -m)/$INSTALL" in
	x86_64/*|*/"dnf -y install"|*/"zypper -n install") $INSTALL egroupware-mail ;;
	*)
		# its dependencies, without egroupware-mail itself
		$INSTALL apache2-utils openssl curl
		cd /opt && apt-get download egroupware-mail:amd64 2>/dev/null || { dpkg --add-architecture amd64; apt-get update; apt-get download egroupware-mail:amd64; }
		dpkg -i --force-architecture --force-depends /opt/egroupware-mail_*_amd64.deb ;;
esac
fi
# the package starts the containers itself, wait for Dovecot (IMAP) and Postfix (SMTP), images are pulled in the postinst
for i in $(seq 90); do
	nc -z 127.0.0.1 143 2>/dev/null && nc -z 127.0.0.1 25 2>/dev/null && break
	sleep 10
done
# the postinst reloads PHP in the egroupware container (kill -s USR2) after changing the config in the DB, wait until EGroupware answers again
for i in $(seq 60); do
	[ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost/egroupware/login.php)" = 200 ] && break
	sleep 5
done
