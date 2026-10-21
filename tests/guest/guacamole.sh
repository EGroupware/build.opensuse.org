#!/bin/bash
# Install Apache Guacamole managed by EGroupware, the way the wiki describes it:
# EGroupware first, secured with https and a certificate (here from an own CA, see tls.sh), then egroupware-guacamole with HTTP_HOST set.
# Runs as root inside the test machine after the egroupware-docker install, the checks are in verify-guacamole.sh.
# Env: TLS_HOST hostname (default egw.test)
set -euxo pipefail
H=${TLS_HOST:-egw.test}
export COMPOSE_PROGRESS=plain
cd "$(dirname "$0")"

# 1. TLS with an own CA for $H, the package expects EGroupware to be reachable via https under its final domain name
TLS_HOST=$H ./tls.sh

# 2. install the package, with HTTP_HOST its %post/postinst patches the domain into the configuration and installs the app with the OpenID client
if command -v apt-get >/dev/null; then INSTALL="apt-get install -y"
elif command -v dnf >/dev/null; then INSTALL="dnf -y install"
else INSTALL="zypper -n install"; fi
HTTP_HOST=$H $INSTALL egroupware-guacamole

# 3. Guacamole fetches the keys of EGroupware's OpenID provider via https, so it has to resolve $H and trust the own CA:
# the (commented) extra_hosts of the override is for this, plus a Java truststore with the CA, as the image has no other way to add a CA
GC=/etc/egroupware-guacamole
IMG=$(docker inspect -f '{{.Config.Image}}' guacamole)
mkdir -p $GC/ca
docker cp guacamole:/opt/java/openjdk/lib/security/cacerts $GC/ca/truststore.jks
cp /etc/egroupware-docker/private-ca.crt $GC/ca/
docker run --rm --user root --entrypoint keytool -v $GC/ca:/ca $IMG -importcert -noprompt -alias private-ca \
	-file /ca/private-ca.crt -keystore /ca/truststore.jks -storepass changeit
chmod 644 $GC/ca/truststore.jks
# uncomment extra_hosts pointing to the docker host (the commented lines in the override have a "#" in place of the first space),
# mount the truststore into the guacamole service (before its image line, guacd has its own) and tell Java to use it
sed -i -e 's|^#\( *\)extra_hosts:| \1extra_hosts:|' \
	-e "s|^#\( *\)- \"[^\"]*\"| \1- \"$H:host-gateway\"|" \
	-e 's|^    image: guacamole/guacamole:|    volumes:\n      - /etc/egroupware-guacamole/ca/truststore.jks:/ca/truststore.jks:ro\n&|' \
	-e 's|^      OPENID_CLIENT_ID:|      JAVA_TOOL_OPTIONS: -Djavax.net.ssl.trustStore=/ca/truststore.jks -Djavax.net.ssl.trustStorePassword=changeit\n&|' \
	$GC/docker-compose.override.yml
cd $GC
if docker compose version >/dev/null 2>&1; then docker compose up -d; else docker-compose up -d; fi

# 4. wait for Guacamole behind the webserver
for i in $(seq 60); do
	[ "$(curl -s -o /dev/null -w '%{http_code}' https://$H/guacamole/api/languages)" = 200 ] && break
	sleep 10
done
curl -sf https://$H/guacamole/api/languages >/dev/null || echo "WARNING: Guacamole does not answer on https://$H/guacamole/, the checks will tell more"
