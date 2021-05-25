#!/bin/bash
############################################################################################################
###
### Script to change Rocket.Chat Site_Url
###
# , bfrom /rocketchat/ to / for recent Rocket.Chat versions no longer supporting a prefix
###
### Usage: ./change-site-url.sh [https://egw.example.org/]
###
### By default - no url given - the no longer supported prefix /rocketchat/ is removed.
###
### Requirements:
### - EGroupware is fully installed including TLS / https with a valid certificate
### - MariaDB/MySQL running either on host or in egroupware-db container
### - if running on host, root user must have no password or a /root/.my.cnf file with correct password!
###
############################################################################################################

# exit on error
set -e

cd $(dirname $0)

# mysql can be on host or in 20.1+ in a container ('db_host' => 'db')
MYSQL=mysql
test -f /etc/egroupware-docker/.env &&
grep "'db_host' => 'db'" /var/lib/egroupware/header.inc.php && {
  source /etc/egroupware-docker/.env
  MYSQL="docker exec -i egroupware-db mysql -uroot -p$EGW_DB_ROOT_PW"
}
# check EGroupware database is accessible
$MYSQL $EGW_DB_NAME --execute "SELECT config_value FROM egw_config WHERE config_name='install_id'" || {
  echo "Can NOT connect to EGroupware database as user 'root', maybe no /root/.my.cnf file with password --> exiting"
  exit 0
}

# make sure Rocket.Chat is stopped and MongoDB up and running
docker-compose stop rocketchat
docker-compose up -d mongo-init-replica
docker logs -f mongo-init-replica 2>/dev/null || true

# change Site_Url
SITE_URL=${1:-$(docker exec -i rocketchat-mongo mongo mongo/rocketchat --eval "db.rocketchat_settings.find({_id: 'Site_Url'}, {value:1});" | \
  grep Site_Url | cut -d'"' -f8 | cut -d/ -f1-3)/}

echo "Changing Site_Url to '$SITE_URL'"
exit

docker exec -i rocketchat-mongo mongo mongo/rocketchat --eval "
db.rocketchat_settings.update({_id: 'Site_Url'}, {\$set: {value: '$SITE_URL', packageValue: '$SITE_URL'}});
"

$MYSQL $EGW_DB_NAME <<EOF
UPDATE egw_openid_clients SET client_redirect_uri='$SITE_URL/_oauth/egroupware' WHERE client_identifier='Rocket.Chat';
REPLACE INTO egw_config (config_app,config_name,config_value) VALUES ('rocketchat','server_url','$SITE_URL');
EOF

# restart EGroupware (php-fpm) to clear the cache
docker exec -i egroupware kill -s USR2 1

# start rocketchat (again)
docker-compose rm -f rocketchat # to get a new / clean log
docker-compose up -d

echo ""
echo "Rocket.Chat URL successful changed to '$SITE_URL"
echo ""
# if running in a terminal, tail the log of starting rocketchat
[ -t 0 -a -t 1 ] && {
  echo "Please wait until Rocket.Chat reports: SERVER RUNNING"
  echo ""
  docker-compose logs -f rocketchat
} || true
