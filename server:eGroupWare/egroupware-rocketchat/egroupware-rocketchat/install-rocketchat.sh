#!/bin/bash
############################################################################################################
###
### Script to (re-)install Rocket.Chat with an empty database AND integrate it via OAuth with EGroupware
###
### Usage: HTTP_HOST=egw.example.org ./install-rocketchat.sh
###
### Requirements:
### - EGroupware is fully installed including TLS / https with a valid certificate
### - MariaDB/MySQL running either on host or in egroupware-db container
### - if running on host, root user must have no password or a /root/.my.cnf file with correct password!
###
### Please note:
### We can only patch a RC 5.x dump with our custom OAuth config, as in RC 6.x the secret is encrypted!
### Therefore we restore a 5.x dump, update OAuth, start with RC 6.x (let it update) and then start RC 7.x!
###
############################################################################################################

# exit on error
set -e

# check if docker compose is available (Ubuntu 24.04 stalls on docker-compose!)
COMPOSE="docker compose"
docker help compose >/dev/null || {
	COMPOSE="docker-compose"
}

# sed inplace for Linux and MacOS
if uname -a | grep -q Darwin
then
  sed_inplace="sed -i ''"
else
  sed_inplace="sed -i"
fi

cd $(dirname $0)

[ -z "$HTTP_HOST" ] && {
  echo "HTTP_HOST environment variable not given for installation --> no EGroupware integration"
  exit 0
}
[[ "$HTTP_HOST" =~ ^[0-9a-z][0-9a-z._-]+[0-9a-z]$ ]] || {
  echo "Invalid HTTP_HOST variable! Please specify fully qualified domain-name like 'egw.example.org'."
  exit 0
}

# values to configure Rocket.Chat and EGroupware
SITE_URL="https://$HTTP_HOST/"
UNIQUE_ID=$(openssl rand -hex 15 | cut -b1-17)
JWT_SECRET=$(openssl rand -base64 40 | cut -b1-43)
ENDPOINT="https://$HTTP_HOST/egroupware/openid/endpoint.php"
CLIENT_ID="Rocket.Chat"
SECRET=$(openssl rand -base64 15)
SECRET_HASH=$(docker exec -i egroupware php -r "echo password_hash('$SECRET', PASSWORD_BCRYPT);")
NOW=$(date "+%Y-%m-%d %H:%M:%S")
EGW_DB_NAME=egroupware

# mysql can be on host or in 20.1+ in a container ('db_host' => 'db')
MYSQL=mysql
test -f /etc/egroupware-docker/.env &&
grep "'db_host' => 'db'" /var/lib/egroupware/header.inc.php && {
  source /etc/egroupware-docker/.env
  MYSQL="docker exec -i egroupware-db mariadb -uroot -p$EGW_DB_ROOT_PW"
}
# check EGroupware database is accessible
$MYSQL $EGW_DB_NAME --execute "SELECT config_value FROM egw_config WHERE config_name='install_id'" || {
  echo "Can NOT connect to EGroupware database as user 'root', maybe no /root/.my.cnf file with password --> exiting"
  exit 0
}

# make sure Rocket.Chat is stopped and MongoDB up and running
$COMPOSE stop rocketchat
$COMPOSE up -d mongo-init-replica
$COMPOSE logs -f mongo-init-replica #>/dev/null || true
# clean uploads dir, but leave dumps intact
rm -rf /var/lib/egroupware/default/rocketchat/uploads/*

# drop database if it exists
docker exec rocketchat-mongo mongosh mongo/rocketchat --eval "db.dropDatabase()"

# create OAuth client in EGroupware
$MYSQL $EGW_DB_NAME <<EOF
DELETE egw_openid_clients,egw_openid_client_grants FROM egw_openid_client_grants INNER JOIN egw_openid_clients USING(client_id) WHERE client_identifier='Rocket.Chat';
INSERT INTO egw_openid_clients (client_name,client_identifier,client_secret,client_redirect_uri,client_created,client_updated,client_status,app_name) VALUES
  ('$CLIENT_ID','$CLIENT_ID','$SECRET_HASH','${SITE_URL}_oauth/egroupware','$NOW','$NOW',1,'rocketchat');
INSERT INTO egw_openid_client_grants (client_id,grant_id)
(SELECT client_id,3 AS grant_id FROM egw_openid_clients WHERE client_identifier='$CLIENT_ID')
UNION
(SELECT client_id,4 AS grant_id FROM egw_openid_clients WHERE client_identifier='$CLIENT_ID')
UNION
(SELECT client_id,5 AS grant_id FROM egw_openid_clients WHERE client_identifier='$CLIENT_ID');
REPLACE INTO egw_config (config_app,config_name,config_value) VALUES
  ('rocketchat','server_url','$SITE_URL'),
  ('rocketchat','authentication','openid'),
  ('rocketchat','oauth_client_id','$CLIENT_ID'),
  ('rocketchat','oauth_service_name','egroupware');
EOF

# restart EGroupware (php-fpm) to clear the cache
docker exec -i egroupware kill -s USR2 1

# patch OAuth URL, client-ID and secret into docker-compose.override.yml
grep Accounts_OAuth_Custom-Egroupware-url docker-compose.override.yml >/dev/null || {
  cat <<EOF | $sed_inplace '/^    environment:/r /dev/stdin' docker-compose.override.yml
    # EGroupware custom OAuth:
    #- Accounts_OAuth_Custom-Egroupware-url=https://example.org/egroupware/openid/endpoint.php
    #- Accounts_OAuth_Custom-Egroupware-id=Rocket.Chat
    #- Accounts_OAuth_Custom-Egroupware-secret=secret
EOF
}
$sed_inplace \
  -e "s|#*- Accounts_OAuth_Custom-Egroupware-url=.*|- Accounts_OAuth_Custom-Egroupware-url=$ENDPOINT|g" \
  -e "s|#*- Accounts_OAuth_Custom-Egroupware-id=.*|- Accounts_OAuth_Custom-Egroupware-id=$CLIENT_ID|g" \
  -e "s|#*- Accounts_OAuth_Custom-Egroupware-secret=.*|- Accounts_OAuth_Custom-Egroupware-secret=$SECRET|g" \
  docker-compose.override.yml

$COMPOSE up -d

echo ""
echo "Rocket.Chat database and OAuth integration successful"
echo "Once Rocket.Chat is started again, you can finish the installation via the Wizard under $SITE_URL"
echo ""
# if running in a terminal, tail the log of starting rocketchat
[ -t 0 -a -t 1 ] && {
  echo "Please wait until Rocket.Chat reports: SERVER RUNNING (exit with ^C)"
  echo ""
  $COMPOSE logs -f rocketchat
} || true