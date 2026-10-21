#!/bin/bash
# Own CA and certificate for a test hostname, TLS on the host's Nginx and the CA trusted by the machine and the
# egroupware container, the way an admin with a private CA would do it (see docker-compose.override.yml of egroupware-docker).
# Needed for the Rocket.Chat OAuth integration, where Rocket.Chat and EGroupware talk to each other via https.
# Only Nginx (the default) is supported, as the host's webserver.
# Env: TLS_HOST hostname, default egw.test
set -euxo pipefail
H=${TLS_HOST:-egw.test}
D=/etc/egroupware-test-tls

if systemctl is-active --quiet apache2 || systemctl is-active --quiet httpd; then
	echo "tls.sh supports only Nginx as webserver" >&2; exit 2
fi
COMPOSE="docker compose"; docker help compose >/dev/null 2>&1 || COMPOSE="docker-compose"

# 1. throw-away CA and a server certificate for $H signed by it, nothing of this is kept anywhere
mkdir -p $D; cd $D
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj "/CN=EGroupware test CA"
openssl req -newkey rsa:2048 -nodes -keyout key.pem -out csr.pem -subj "/CN=$H"
printf "subjectAltName=DNS:$H\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" > ext.cnf
openssl x509 -req -in csr.pem -CA ca.pem -CAkey ca.key -CAcreateserial -out cert.pem -days 2 -extfile ext.cnf
openssl verify -CAfile ca.pem cert.pem

# 2. the documented place for the private CA of the containers
cp ca.pem /etc/egroupware-docker/private-ca.crt

# 3. trust it on the machine itself and make the name resolve
if [ -d /etc/pki/ca-trust/source/anchors ]; then
	cp ca.pem /etc/pki/ca-trust/source/anchors/egw-test-ca.crt; update-ca-trust
elif [ -d /etc/pki/trust/anchors ]; then
	cp ca.pem /etc/pki/trust/anchors/egw-test-ca.crt; update-ca-certificates
else
	mkdir -p /usr/local/share/ca-certificates; cp ca.pem /usr/local/share/ca-certificates/egw-test-ca.crt; update-ca-certificates
fi
grep -q " $H\$" /etc/hosts || echo "127.0.0.1 $H" >> /etc/hosts

# 4. TLS on the host's Nginx: uncomment the documented listen line and add the certificate
grep -q "^	listen 443" /etc/egroupware-docker/nginx.conf || \
	sed -i "s|^\t#listen 443 ssl http2 default_server;|\tlisten 443 ssl default_server;\n\tssl_certificate $D/cert.pem;\n\tssl_certificate_key $D/key.pem;|" /etc/egroupware-docker/nginx.conf
grep -q "^	listen 443" /etc/egroupware-docker/nginx.conf
nginx -t
systemctl reload nginx

# 5. egroupware container: mount the CA (its entrypoint adds it to the system store and PHP) and resolve $H to the host
cd /etc/egroupware-docker
O=docker-compose.override.yml
sed -i -e '/^  egroupware:/,/^  [a-z-]*:/ s|^    #volumes:|    volumes:|' \
       -e "s|^    #- /etc/egroupware-docker/private-ca.crt|    - /etc/egroupware-docker/private-ca.crt|" \
       -e "s|^    #extra_hosts:|    extra_hosts:|" \
       -e "s|^    #- \"my.host.name:ip-address\"|    - \"$H:host-gateway\"|" $O
grep -q "^    - /etc/egroupware-docker/private-ca.crt" $O && grep -q "^    - \"$H:host-gateway\"" $O
$COMPOSE up -d egroupware

# 6. wait until EGroupware answers via https with the new certificate, without -k
for i in $(seq 60); do
	[ "$(curl -s -o /dev/null -w '%{http_code}' https://$H/egroupware/login.php)" = 200 ] && break
	sleep 5
done
curl -sf -o /dev/null https://$H/egroupware/login.php
echo "TLS with own CA ready: https://$H/"
