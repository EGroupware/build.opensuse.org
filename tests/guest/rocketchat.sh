#!/bin/bash
# Install Rocket.Chat with the OAuth integration into EGroupware, the way the wiki describes it:
# EGroupware first, with TLS and a certificate (here from an own CA, see tls.sh), then egroupware-rocketchat with HTTP_HOST set.
# Runs as root inside the test machine after the egroupware-docker install, the checks are in verify-rocketchat.sh.
# Env: TLS_HOST hostname (default egw.test),
#      RC_OVERLAY directory with files of the package (docker-compose.yml, install-rocketchat.sh, ...) to test an unreleased version:
#                 the published package is installed WITHOUT HTTP_HOST, the files are copied over it and install-rocketchat.sh is run by hand
set -euxo pipefail
H=${TLS_HOST:-egw.test}
export COMPOSE_PROGRESS=plain
COMPOSE="docker compose"; docker help compose >/dev/null 2>&1 || COMPOSE="docker-compose"
cd "$(dirname "$0")"

# 1. TLS with an own CA for $H
TLS_HOST=$H ./tls.sh

# 2. Rocket.Chat needs an email address for the users logging in via OAuth, the default sysop has none
source /etc/egroupware-docker/.env
docker exec -i egroupware-db mariadb -uroot -p"$EGW_DB_ROOT_PW" egroupware -e \
	"UPDATE egw_addressbook SET contact_email='sysop@$H' WHERE account_id=(SELECT account_id FROM egw_accounts WHERE account_lid='sysop')"
docker exec egroupware kill -s USR2 1   # clear the account cache of php-fpm
sleep 5

# 3. install the package: with HTTP_HOST its %post runs install-rocketchat.sh, which configures the OAuth integration
if command -v apt-get >/dev/null; then INSTALL="apt-get install -y"
elif command -v dnf >/dev/null; then INSTALL="dnf -y install"
else INSTALL="zypper -n install"; fi
if [ -n "${RC_OVERLAY:-}" ] && [ -d "$RC_OVERLAY" ]; then
	$INSTALL egroupware-rocketchat
	cp -a "$RC_OVERLAY"/. /etc/egroupware-rocketchat/
	# what %post does for HTTP_HOST, before it runs the install script
	sed -i "s#ROOT_URL=.*#ROOT_URL=https://$H/#g" /etc/egroupware-rocketchat/docker-compose.override.yml
	( cd /etc/egroupware-rocketchat && HTTP_HOST=$H ./install-rocketchat.sh )
else
	HTTP_HOST=$H $INSTALL egroupware-rocketchat
fi

# 4. the CA for Rocket.Chat as documented in its docker-compose.override.yml (mount and NODE_EXTRA_CA_CERTS),
#    the name of the host has to resolve to the docker host for it too (an admin has a DNS name for it)
cd /etc/egroupware-rocketchat
O=docker-compose.override.yml
sed -i -e '/^  rocketchat:/,/^  [a-z-]*:/ s|^    #volumes:|    volumes:|' \
       -e "s|^    # - /etc/egroupware-docker/private-ca.crt|    - /etc/egroupware-docker/private-ca.crt|" \
       -e "s|^    # - NODE_EXTRA_CA_CERTS=|    - NODE_EXTRA_CA_CERTS=|" $O
grep -q "^    extra_hosts:" $O || sed -i "s|^  rocketchat:|  rocketchat:\n    extra_hosts:\n    - \"$H:host-gateway\"|" $O
grep -q "^    - NODE_EXTRA_CA_CERTS=" $O && grep -q "^    - /etc/egroupware-docker/private-ca.crt" $O
$COMPOSE up -d rocketchat

# 5. wait for Rocket.Chat behind the webserver
for i in $(seq 60); do
	curl -sf https://$H/api/info >/dev/null 2>&1 && break
	sleep 10
done
curl -sf https://$H/api/info || echo "WARNING: Rocket.Chat does not answer on https://$H/api/info, the checks will tell more"
