#!/bin/bash
# Success criteria for an installed egroupware-docker, shared by all distros. Extend here!
# Env: TIMEOUT seconds to wait for containers/webserver (default 1800, emulation is slow)
TIMEOUT=${TIMEOUT:-1800}
# with Apache the RHEL/Rocky packages only have an https vhost with a self-signed certificate: WEB_BASE=https://localhost, curl then needs -k
BASE=${WEB_BASE:-http://localhost}
case $BASE in https:*) [ -n "${TLS_TRUSTED:-}" ] || echo insecure > /root/.curlrc ;; esac   # TLS_TRUSTED: own CA is trusted, certificate is checked
fail=0
ok()  { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

# --- static criteria (right after install) ---
check "docker service enabled"                  systemctl is-enabled docker
check "docker service active"                   systemctl is-active docker
if docker compose version >/dev/null 2>&1; then ok "docker compose v2 plugin available"
elif docker-compose version >/dev/null 2>&1; then echo "WARN: no docker compose plugin for this distro, only the old docker-compose script ($(docker-compose version --short 2>/dev/null))"
else bad "neither docker compose plugin nor docker-compose available"; fi
check "/etc/egroupware-docker/docker-compose.yml exists"        test -f /etc/egroupware-docker/docker-compose.yml
check "/etc/egroupware-docker/docker-compose.override.yml exists" test -f /etc/egroupware-docker/docker-compose.override.yml
check "install log with credentials exists"     test -s /var/lib/egroupware/egroupware-docker-install.log
check "header.inc.php exists"                   test -s /var/lib/egroupware/header.inc.php

# --- runtime criteria (wait until up) ---
CONTAINERS="egroupware egroupware-db egroupware-push egroupware-nginx egroupware-watchtower"
deadline=$((SECONDS+TIMEOUT))
until [ "$(curl -s -o /dev/null -w '%{http_code}' $BASE/egroupware/login.php)" = 200 ] || [ $SECONDS -ge $deadline ]; do sleep 10; done
for c in $CONTAINERS; do
	check "container $c running" test "$(docker inspect -f '{{.State.Running}}' $c)" = true
done
code=$(curl -s -o /dev/null -w '%{http_code}' $BASE/egroupware/login.php)
[ "$code" = 200 ] && ok "$BASE/egroupware/login.php returns 200" || bad "login.php returned $code"

# --- installation actually succeeded: install log with credentials, and they work against the REST API ---
LOG=/var/lib/egroupware/egroupware-docker-install.log
check "install log reports 'EGroupware successful installed'" grep -q 'EGroupware successful installed' $LOG
check "install log is only readable by root (mode 600)"        test "$(stat -c %a $LOG)" = 600
# passwords are only kept in variables, never printed
ADMIN_PW=$(awk '/^Setup username: *admin/{f=1;next} f&&/password:/{print $2;exit}' $LOG)
SYSOP_PW=$(awk '/^EGroupware username: *sysop/{f=1;next} f&&/password:/{print $2;exit}' $LOG)
check "install log contains password of setup user admin"      test -n "$ADMIN_PW"
check "install log contains password of EGroupware user sysop" test -n "$SYSOP_PW"
REST=$BASE/egroupware/groupdav.php
code=$(curl -s -o /tmp/accounts.json -w '%{http_code}' -u "sysop:$SYSOP_PW" -H 'Accept: application/json' $REST/addressbook-accounts/)
[ "$code" = 200 ] && ok "REST: sysop lists accounts-addressbook (200)" || bad "REST: accounts-addressbook returned $code"
check "REST: accounts list is JSON with responses"             grep -q '"responses"' /tmp/accounts.json
# sysop's account contact is "Admin User", the login name itself is not part of the contact
check "REST: accounts list contains sysop's contact 'Admin User'" grep -q '"fullName":"Admin User"' /tmp/accounts.json
code=$(curl -s -o /dev/null -w '%{http_code}' -u "sysop:$SYSOP_PW" -H 'Accept: application/json' $REST/principals/users/sysop/)
[ "$code" = 200 ] && ok "REST: principal of user sysop exists (200)" || bad "REST: principals/users/sysop/ returned $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -u "sysop:wrong-$SYSOP_PW" -H 'Accept: application/json' $REST/addressbook-accounts/)
[ "$code" = 401 ] && ok "REST: wrong password is rejected (401)" || bad "REST: wrong password returned $code, expected 401"
rm -f /tmp/accounts.json

# the REST calls above went through $BASE, so through the host's webserver (Nginx by default, Apache if installed with apache2),
# which proxies to the egroupware-nginx container (127.0.0.1:8080), which talks to PHP-FPM in the egroupware container
WEBLOG=""; for l in /var/log/nginx/access.log /var/log/apache2/access.log /var/log/apache2/access_log /var/log/httpd/ssl_access_log /var/log/httpd/access_log; do [ -s $l ] && WEBLOG=$l && break; done
# the user is only in nginx's access log, Apache logs "-" as it does not do the authentication itself
if [ -n "$WEBLOG" ] && grep -q "\"GET /egroupware/groupdav.php/addressbook-accounts/ HTTP/1.1\" 200" $WEBLOG; then
	ok "REST request passed the host webserver (found in $WEBLOG, status 200)"
else
	bad "REST request not found in host webserver access log (${WEBLOG:-no access log found})"
fi
if systemctl is-active --quiet nginx; then WS=nginx; else WS=apache; fi
# Apache passes the Server header of the proxied egroupware-nginx container through, so it only identifies Nginx as front webserver
[ $WS != nginx ] || check "host nginx is the webserver answering $BASE (Server header)" sh -c "curl -sI $BASE/egroupware/ | grep -qi '^server: nginx'"
code=$(curl -s -o /dev/null -w '%{http_code}' -u "sysop:$SYSOP_PW" -H 'Accept: application/json' http://127.0.0.1:8080/egroupware/groupdav.php/addressbook-accounts/)
[ "$code" = 200 ] && ok "REST also answers directly from the egroupware-nginx container on 127.0.0.1:8080 (200)" || bad "egroupware-nginx container on 127.0.0.1:8080 returned $code"

# setup user admin: setup-cli.php with the logged password (via EGW_CLI_PASSWORD, so it never shows up in a process list or log)
# --config without name=value is the least invasive command requiring the config user, it just prints the configuration
SETUP_CLI="docker exec -e EGW_CLI_PASSWORD egroupware php /usr/share/egroupware/setup/setup-cli.php"
out=$(EGW_CLI_PASSWORD="$ADMIN_PW" $SETUP_CLI --config default,admin 2>&1); rc=$?
[ $rc = 0 ] && echo "$out" | grep -q 'Current configuration' && ok "setup-cli.php: setup user admin can authenticate (exit 0)" || bad "setup-cli.php: admin with logged password failed, exit $rc"
out=$(EGW_CLI_PASSWORD="wrong-$ADMIN_PW" $SETUP_CLI --config default,admin 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q 'wrong username or password' && ok "setup-cli.php: wrong admin password is rejected (exit $rc)" || bad "setup-cli.php: wrong admin password not rejected, exit $rc"

# exactly the default accounts exist (REST only shows what sysop can see, so ask the database via the package's mysql.sh)
EXPECTED_ACCOUNTS="g:Admins g:Default g:NoGroup g:Teachers u:anonymous u:sysop"
# egroupware-mail adds the master user dovecot
[ "${EXPECT_MAIL:-0}" != 1 ] || EXPECTED_ACCOUNTS="g:Admins g:Default g:NoGroup g:Teachers u:anonymous u:dovecot u:sysop"
ACTUAL_ACCOUNTS=$(/etc/egroupware-docker/mysql.sh -N -e "SELECT CONCAT(account_type,':',account_lid) FROM egw_accounts" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
if [ "$ACTUAL_ACCOUNTS" = "$EXPECTED_ACCOUNTS" ]; then
	ok "accounts are exactly users sysop, anonymous and groups Admins, Default, NoGroup, Teachers"
else
	bad "accounts differ: expected [$EXPECTED_ACCOUNTS] got [$ACTUAL_ACCOUNTS]"
fi

# --- web server: Nginx is preferred, Apache only if installed or requested, and then Nginx must NOT be pulled in ---
if [ -n "${EXPECT_WEBSERVER:-}" ]; then
	if dpkg -s nginx >/dev/null 2>&1 || rpm -q nginx >/dev/null 2>&1; then HAS_NGINX=1; else HAS_NGINX=0; fi
	if dpkg -s apache2 >/dev/null 2>&1 || rpm -q httpd >/dev/null 2>&1 || rpm -q apache2 >/dev/null 2>&1; then HAS_APACHE=1; else HAS_APACHE=0; fi
	if [ "$EXPECT_WEBSERVER" = nginx ]; then
		[ $HAS_NGINX = 1 -a $HAS_APACHE = 0 ] && ok "web server: Nginx installed, Apache not (Nginx is preferred)" || bad "web server: expected only Nginx, got nginx=$HAS_NGINX apache=$HAS_APACHE"
	else
		[ $HAS_APACHE = 1 -a $HAS_NGINX = 0 ] && ok "web server: Apache installed as requested, Nginx not pulled in" || bad "web server: expected only Apache, got nginx=$HAS_NGINX apache=$HAS_APACHE"
		check "web server: Apache service active" sh -c "systemctl is-active --quiet apache2 || systemctl is-active --quiet httpd"
	fi
fi

# --- egroupware-collabora-key (Recommends of egroupware-docker): image depends on architecture, CODE on arm64 ---
if dpkg -s egroupware-collabora-key >/dev/null 2>&1 || rpm -q egroupware-collabora-key >/dev/null 2>&1; then
	case "$(uname -m)" in aarch64|arm64) IMG=collabora/code:latest ;; *) IMG=quay.io/egroupware/collabora-key:stable ;; esac
	check "collabora-key: compose file uses $IMG on $(uname -m)" grep -q "^ *image: *\"$IMG\"" /etc/egroupware-collabora-key/docker-compose.yml
	deadline=$((SECONDS+TIMEOUT))
	until curl -sf http://127.0.0.1:9980/hosting/discovery 2>/dev/null | grep -q wopi-discovery || [ $SECONDS -ge $deadline ]; do sleep 10; done
	check "collabora-key: container running"                       test "$(docker inspect -f '{{.State.Running}}' collabora-key)" = true
	check "collabora-key: container runs image $IMG"               test "$(docker inspect -f '{{.Config.Image}}' collabora-key)" = "$IMG"
	check "collabora-key: /hosting/discovery answers on 127.0.0.1:9980" sh -c "curl -sf http://127.0.0.1:9980/hosting/discovery | grep -q wopi-discovery"
	check "collabora-key: /hosting/discovery answers through the host webserver" sh -c "curl -sf $BASE/hosting/discovery | grep -q wopi-discovery"
elif [ "${EXPECT_COLLABORA:-0}" = 1 ]; then
	bad "egroupware-collabora-key (Recommends) was not installed"
else
	echo "SKIP: egroupware-collabora-key not installed (--no-install-recommends)"
fi

# --- egroupware-rocketchat with OAuth integration into EGroupware (ROCKETCHAT=1 of run-test.sh) ---
if [ "${EXPECT_ROCKETCHAT:-0}" = 1 ]; then . "$(dirname "$0")/verify-rocketchat.sh"; fi

# --- egroupware-guacamole with OpenID login via EGroupware (GUACAMOLE=1 of run-test.sh) ---
if [ "${EXPECT_GUACAMOLE:-0}" = 1 ]; then . "$(dirname "$0")/verify-guacamole.sh"; fi

# --- egroupware-mail: Dovecot and Postfix integrated into EGroupware (MAIL=1 of run-test.sh) ---
if [ "${EXPECT_MAIL:-0}" = 1 ]; then . "$(dirname "$0")/verify-mail.sh"; fi

[ $fail = 0 ] && echo "ALL CRITERIA PASSED" || { echo "SOME CRITERIA FAILED"; docker ps -a; }
exit $fail
