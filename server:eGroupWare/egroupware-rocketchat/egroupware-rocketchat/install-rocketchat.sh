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
############################################################################################################

# exit on error
set -e

# check if docker compose is available (Ubuntu 24.04 stalls on docker-compose!)
COMPOSE="docker compose"
docker help compose >/dev/null || {
	COMPOSE="docker-compose"
}

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
  MYSQL="docker exec -i egroupware-db mysql -uroot -p$EGW_DB_ROOT_PW"
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
docker exec rocketchat-mongo mongo mongo/rocketchat --eval "db.dropDatabase()"

# restore empty rocketchat installation with configured OAuth for EGroupware
cat mongodump-rocketchat-5.4.gz | docker exec -i rocketchat-mongo mongorestore --gzip --archive #--noIndexRestore
#docker exec rocketchat-mongo mongo rocketchat --eval 'db.runCommand({dropIndexes: "users", index: "bio_1"});'

docker exec -i rocketchat-mongo mongo mongo/rocketchat --eval "
db.meteor_accounts_loginServiceConfiguration.update({service: 'egroupware'}, {
  service : 'egroupware',
  accessTokenParam: 'access_token',
  authorizePath: '/authorize',
  buttonColor: '#1d74f5',
  buttonLabelColor: '#FFFFFF',
  buttonLabelText: 'EGroupware users click here',
  clientId: '$CLIENT_ID',
  custom: true,
  identityPath: '/userinfo',
  identityTokenSentVia: 'header',
  loginStyle: 'redirect',
  mergeRoles: true,
  rolesToMerge: 'admin',
  mergeUsers: true,
  rolesClaim: 'roles',
  scope: 'openid email profile roles groupes',
  secret: '$SECRET',
  serverURL: '$ENDPOINT',
  tokenPath: '/access_token',
  tokenSentVia: 'payload',
  usernameField: 'id'
}, {upsert: true});
db.rocketchat_settings.update({_id: 'Accounts_OAuth_Custom-Egroupware'},
  {\$set: {value: true, hidden: true, packageValue: true}});
db.rocketchat_settings.update({_id: 'Accounts_OAuth_Custom-Egroupware-id'},
  {\$set: {value: '$CLIENT_ID', packageValue: '$CLIENT_ID', hidden: false}});
db.rocketchat_settings.update({_id: 'Accounts_OAuth_Custom-Egroupware-secret'},
  {\$set: {value: '$SECRET', packageValue: '$SECRET', hidden: false}});
db.rocketchat_settings.update({_id: 'Accounts_OAuth_Custom-Egroupware-url'},
  {\$set: {value: '$ENDPOINT', packageValue: '$ENDPOINT', hidden: false}});
db.rocketchat_settings.update({_id: 'Site_Url'}, {\$set: {value: '$SITE_URL', packageValue: '$SITE_URL'}});
db.rocketchat_settings.update({_id: 'uniqueID'}, {\$set: {value: '$UNIQUE_ID', installedAt: '$NOW'}});
db.rocketchat_settings.update({_id: 'FileUpload_json_web_token_secret_for_files'},
  {\$set: {value: '$JWT_SECRET', installedAt: '$NOW'}});
db.rocketchat_settings.update({_id: 'Jitsi_Enabled'}, {\$set: {value: true}});
db.rocketchat_settings.update({_id: 'Jitsi_Domain'}, {\$set: {value: 'meet.jit.si'}});
db.rocketchat_settings.update({_id: 'Jitsi_Enabled_TokenAuth'}, {\$set: {value: false}});
db.rocketchat_settings.update({_id: 'Jitsi_Application_ID'}, {\$set: {value: ''}});
db.rocketchat_settings.update({_id: 'Jitsi_Application_Secret'}, {\$set: {value: ''}});
db.rocketchat_settings.updateMany({_id: /^Organization/}, {\$set: {value: ''}});
db.rocketchat_settings.update({_id: 'Show_Setup_Wizard'}, {\$set: {value: 'pending'}});
db.rocketchat_settings.updateMany({_id: /^Cloud_Workspace_/}, {\$set: {value: ''}});
db.rocketchat_settings.updateMany({_id: /^Iframe_Integration_.*_enable/}, {\$set: {value: true }});
db.rocketchat_settings.update({_id: 'Accounts_TwoFactorAuthentication_Enabled'}, {\$set: {value: false}});
db.rocketchat_settings.update({_id: 'Accounts_ForgetUserSessionOnWindowClose'}, {\$set: {value: true}});
db.rocketchat_settings.update({_id: 'Accounts_AllowUsernameChange'}, {\$set: {value: false}});
db.rocketchat_settings.update({_id: 'Accounts_AllowEmailChange'}, {\$set: {value: false}});
db.rocketchat_settings.update({_id: 'Accounts_AllowPasswordChange'}, {\$set: {value: false}});
db.rocketchat_settings.update({_id: 'Accounts_AllowPasswordChangeForOAuthUsers'}, {\$set: {value: false}});
db.rocketchat_settings.update({_id: 'Accounts_ShowFormLogin'}, {\$set: {value: false}});
db.rocketchat_settings.update({_id: 'Accounts_RegistrationForm'}, {\$set: {value: 'Public'}}); // was 'Disabled'
db.rocketchat_settings.update({_id: 'FileUpload_Storage_Type'}, {\$set: {value: 'FileSystem'}});
db.rocketchat_settings.update({_id: 'FileUpload_FileSystemPath'}, {\$set: {value: '/app/uploads'}});
db.getCollection('_raix_push_app_tokens').remove({});
// remove all users, but rocket.cat
db.users.remove({_id: {\$ne: 'rocket.cat'}});
"

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

# start rocketchat (again)
$COMPOSE rm -f rocketchat # to get a new / clean log
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