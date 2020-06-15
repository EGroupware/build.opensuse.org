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
  # add override to disable internal db for update
  echo -e "\n\n#disable internal db service\n  db:\n    image: busybox\n    entrypoint: /bin/true\n    restart: never\n" >> docker-compose.override.yml
  cp latest-docker-compose.yml docker-compose.yml
  # we also need to add websocket proxy to webserver on the host
  grep -q "required for push" apache.conf || cat<<EOF >> apache.conf
# required for push / websocket
ProxyPass /egroupware/push ws://127.0.0.1:8080/egroupware/push nocanon
EOF
  grep -q "required for push" nginx.conf || {
    (sed '/location \/egroupware {/q' nginx.conf
    cat <<EOF
		# required for push / websocket
		proxy_http_version 1.1;
		proxy_set_header Upgrade $http_upgrade;
		proxy_set_header Connection "Upgrade";
EOF
    sed -e '1,/location \/egroupware {/ d' nginx.conf) > new-nginx.conf
    mv new-nginx.conf nginx.conf
  }
}

# if we have no docker-compose.override.yml create it from latest-docker-compose.override.yml
test -f docker-compose.override.yml || cp latest-docker-compose.override.yml docker-compose.override.yml

# new install: create .env file with MariaDB root password
test -f .env || echo -e "# MariaDB root password\nEGW_DB_ROOT_PW=$(openssl rand --hex 16)\n" > .env
