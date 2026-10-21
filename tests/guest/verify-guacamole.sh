# Checks of the egroupware-guacamole package and its OpenID login via EGroupware, sourced by verify.sh (uses ok, bad, check, $BASE, $TIMEOUT)
GCDIR=/etc/egroupware-guacamole
OV=$GCDIR/docker-compose.override.yml
HOST=${TLS_HOST:-egw.test}

check "guacamole: container guacamole running"      test "$(docker inspect -f '{{.State.Running}}' guacamole)" = true
check "guacamole: container guacamole-guacd running" test "$(docker inspect -f '{{.State.Running}}' guacamole-guacd)" = true

# configuration written by the package
check "guacamole: docker-compose.override.yml created" test -f $OV
check "guacamole: HTTP_HOST patched into the override (no example.org left)" sh -c "! grep -q example.org $OV"
check "guacamole: OpenID endpoint uses https://$HOST" grep -q "OPENID_AUTHORIZATION_ENDPOINT: https://$HOST/egroupware/openid/endpoint.php/authorize" $OV
GPW=$(sed -n 's/^ *MYSQL_PASSWORD: *//p' $OV)
check "guacamole: random database password generated (32 hex chars, not the placeholder)" sh -c "echo '$GPW' | grep -qE '^[0-9a-f]{32}$'"

# the app in EGroupware, its database objects and the OpenID client, all created by the package
ROOTPW=$(sed -n 's/^EGW_DB_ROOT_PW=//p' /etc/egroupware-docker/.env)
dbroot() { docker exec -i egroupware-db mariadb -uroot -p"$ROOTPW" egroupware -N -e "$1" 2>/dev/null; }
[ "$(dbroot "SELECT COUNT(*) FROM egw_applications WHERE app_name='guacamole'")" = 1 ] && ok "guacamole: app is installed in EGroupware" || bad "guacamole: app is not installed in EGroupware"
[ "$(dbroot "SELECT client_redirect_uri FROM egw_openid_clients WHERE client_identifier='guacamole'")" = "https://$HOST/guacamole/" ] \
	&& ok "guacamole: OpenID client guacamole exists with redirect https://$HOST/guacamole/" || bad "guacamole: OpenID client missing or with another redirect URI"
n=$(docker exec -i egroupware-db mariadb -uguacamole -p"$GPW" egroupware -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='egroupware' AND table_name LIKE 'guacamole\_%'" 2>/dev/null)
[ "${n:-0}" -gt 0 ] && ok "guacamole: database user guacamole can log in and sees $n guacamole_* tables/views" || bad "guacamole: database user guacamole can not log in or sees no guacamole_* tables/views"

# Guacamole behind the webserver
deadline=$((SECONDS+TIMEOUT))
until [ "$(curl -s -o /dev/null -w '%{http_code}' $BASE/guacamole/api/languages)" = 200 ] || [ $SECONDS -ge $deadline ]; do sleep 10; done
check "guacamole: $BASE/guacamole/api/languages answers through the webserver" sh -c "curl -sf $BASE/guacamole/api/languages | grep -q '\"en\"'"
check "guacamole: the OpenID extension is loaded" sh -c "docker logs guacamole 2>&1 | grep -qi 'openid'"
echo "INFO: Guacamole image $(docker inspect -f '{{.Config.Image}}' guacamole) $(docker inspect -f '{{.Image}}' guacamole | cut -c1-19), guacd $(docker inspect -f '{{.Config.Image}}' guacamole-guacd)"

# the whole OpenID login of EGroupware user sysop, without a browser:
# 1. Guacamole tells where to authenticate (with a nonce only it knows), 2. EGroupware issues an id_token (implicit grant, no consent for an EGroupware app),
# 3. Guacamole validates the id_token with the keys it fetches from EGroupware via https (needs the private CA in its Java truststore)
SYSOP_PW=$(awk '/^EGroupware username: *sysop/{f=1;next} f&&/password:/{print $2;exit}' /var/lib/egroupware/egroupware-docker-install.log)
J=/tmp/guac-oidc.cookies; rm -f $J
# an (empty) form body is required, otherwise Guacamole answers "Unexpected internal error: The @FormParam is utilized when the content ..."
EXPECTED=$(curl -s -X POST -d "" $BASE/guacamole/api/tokens)
AUTHURL=$(echo "$EXPECTED" | sed -n 's/.*"redirectUrl":"\([^"]*\)".*/\1/p' | sed -e 's/\\u0026/\&/g' -e 's|\\/|/|g')
case "$AUTHURL" in "https://$HOST/egroupware/openid/endpoint.php/authorize?"*) ok "oauth: Guacamole asks for authentication at EGroupware's OpenID endpoint" ;;
	*) bad "oauth: Guacamole did not return an authorization URL: ${EXPECTED:0:200}" ;; esac
# log in as sysop and authorize, retried a while: right after the app installation EGroupware's session handling may not be ready yet
for i in 1 2 3 4 5 6; do
	rm -f $J; curl -s -c $J -b $J -o /dev/null -d "login=sysop&passwd=$SYSOP_PW&passwd_type=text&account_type=u&submitit=1" $BASE/egroupware/login.php
	LOC=$(curl -s -b $J -c $J -o /dev/null -w '%{redirect_url}' "$AUTHURL")
	JWT=$(echo "$LOC" | sed -n 's/.*[#&?]id_token=\([^&]*\).*/\1/p')
	[ -n "$JWT" ] && break; sleep 10
done
[ -n "$JWT" ] && ok "oauth: EGroupware issues an id_token for client guacamole (no consent screen)" || bad "oauth: no id_token from EGroupware: '${LOC:0:150}'"
RES=$(curl -s -X POST $BASE/guacamole/api/tokens -d "id_token=$JWT")
if echo "$RES" | grep -q '"authToken"' && echo "$RES" | grep -q '"username":"sysop"'; then
	ok "oauth: Guacamole accepts the id_token and logs in user sysop"
else
	bad "oauth: Guacamole rejected the id_token: ${RES:0:200} | log: $(docker logs --since 5m guacamole 2>&1 | grep -iE 'error|exception|PKIX|certificate|jwks|nonce' | head -3 | cut -c1-220 | tr '\n' ' ')"
fi
