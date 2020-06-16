#!/bin/bash
#####################################################
### Create docker-compose.override.yml either from:
### - pre 20.1 docker-compose.yml or
### - latest-docker-compose.override.yml
#####################################################

cd /etc/egroupware-docker

# for an upgrade check that the EPL image was not accidentally removed by agreeing on taking the packages version
if [ -n "$2" -a -f docker-compose.yml.dpkg-old ] && \
  grep -q "^\s*image:\s*download.egroupware.org/egroupware/epl:" docker-compose.yml.dpkg-old
then
  sed -i 's|egroupware/egroupware:|download.egroupware.org/egroupware/epl:|' docker-compose.yml
fi

# if we have no .override file, identical (latest-)docker-compose.yml and an docker-compose.yml.dpkg-old
# user thought he was clever to not take the default to keep docker-compose.yml, use it to create .override
test -f docker-compose.override.yml || diff -q docker-compose.yml latest-docker-compose.yml && \
  test -f docker-compose.yml.dpkg-old && {
    mv docker-compose.yml.dpkg-old docker-compose.yml
}

# if we have no .override file and docker-compose.yml is not identical to latest-docker-compose.yml
# we assume an update from before 20.1 and create .override from stock .override and old docker-compose.yml
test -f docker-compose.override.yml || diff -q docker-compose.yml latest-docker-compose.yml || {
  # docker-compose.override.yml need to be fully commented out, to safely concatenate with docker-compose.yml
  sed '/^ *#/! s/^\(.\)/#\1/g' latest-docker-compose.override.yml | \
    cat - docker-compose.yml > docker-compose.override.yml
  # until 20.1 is latest, replace latest with 20.1
  sed -e 's|egroupware/egroupware:latest|egroupware/egroupware:20.1|g' \
      -e 's|download.egroupware.org/egroupware/epl:latest|download.egroupware.org/egroupware/epl:20.1|g' \
      -i docker-compose.override.yml
  # ^^^ until 20.1 is latest, replace latest with 20.1 ^^^
  cp latest-docker-compose.yml docker-compose.yml
  # we also need to add websocket proxy to apache on the host
  grep -q "required for push" apache.conf || cat<<EOF >> apache.conf
# required for push / websocket
ProxyPass /egroupware/push ws://127.0.0.1:8080/egroupware/push nocanon
EOF
}

# if we have no docker-compose.override.yml create it from latest-docker-compose.override.yml
test -f docker-compose.override.yml || cp latest-docker-compose.override.yml docker-compose.override.yml

# if we don't need the internal db (eg. update from 19.1), disable it (new installs have a minimal header.inc.php!)
test -f /var/lib/egroupware/header.inc.php && grep -q "'db_host'" /var/lib/egroupware/header.inc.php && {
  grep -q "'db_host' => 'db'," /var/lib/egroupware/header.inc.php || \
    cat <<EOF >> docker-compose.override.yml

  #disable internal db service
  db:
    image: busybox
    entrypoint: /bin/true
    restart: "no"
EOF
}

# new install: create .env file with MariaDB root password
test -f .env || echo -e "# MariaDB root password\nEGW_DB_ROOT_PW=$(openssl rand -hex 16)\n" > .env
