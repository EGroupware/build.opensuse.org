#!/bin/bash
###################################################################################################
### Create docker-compose.override.yml in either of the following three cases:
### 1. update from 19.1 with docker-compose.yml modification: use pre 20.1 docker-compose.yml
### 2. update from 19.1 or before without docker-compose.yml modification: create .override with 19.1 defaults
### 3. new install: use latest-docker-compose.override.yml
###################################################################################################

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

# case 1: 19.1 update with docker-compose.yml modification
# we have no .override file and docker-compose.yml is not identical to latest-docker-compose.yml
# we assume an update from before 21.1 and create .override from stock .override and old docker-compose.yml
test -f docker-compose.override.yml || diff -q docker-compose.yml latest-docker-compose.yml || {
  # docker-compose.override.yml need to be fully commented out, to safely concatenate with docker-compose.yml
  sed '/^ *#/! s/^\(.\)/#\1/g' latest-docker-compose.override.yml | \
    cat - docker-compose.yml > docker-compose.override.yml
  # replace latest with 21.1, to tie major release updates to package-updates
  sed -e 's|egroupware/egroupware:latest|egroupware/egroupware:21.1|g' \
      -e 's|download.egroupware.org/egroupware/epl:latest|download.egroupware.org/egroupware/epl:21.1|g' \
      -i docker-compose.override.yml
  # disable internal database container (also happens for a modified/included old docker-compose.yml)
  cat <<EOF >> docker-compose.override.yml

  #disable internal db service
  db:
    image: busybox
    entrypoint: /bin/true
    restart: "no"
EOF
  cp latest-docker-compose.yml docker-compose.yml
}

# case 2: 19.1 or earlier update without docker-compose.yml modification
# we have no .override, but a header.inc.php with 'db_host' => 'localhost', this is a clean 19.1 update
# (without docker-compose.yml modification) --> create nice minimal override for external db
test -f docker-compose.override.yml || {
  test -f /var/lib/egroupware/header.inc.php && grep -q "'db_host' => 'localhost'" /var/lib/egroupware/header.inc.php && {
    cp latest-docker-compose.override.yml docker-compose.override.yml
    cat <<EOF | patch -p0 docker-compose.override.yml
--- docker-compose.override.yml	2020-06-16 10:50:49.000000000 +0200
+++ docker-compose.override-19.1.yml	2020-06-17 09:16:46.000000000 +0200
@@ -36,7 +36,7 @@
     # - 21.1: use a branch to keep on latest maintenance release for that branch, but not update automatic to next release
     # - 21.1.20210521: use a maintenance release, to disable automatic updates via watchtower and run them manually
     image: egroupware/egroupware:21.1
-    #volumes:
+    volumes:
     # if you want to use the host database:
     # 1. follow instructions below to disable db service
     # 2. set EGW_DB_HOST=localhost AND
@@ -44,15 +44,15 @@
     #    - RHEL/CentOS   /var/lib/mysql/mysql.sock:/var/run/mysqld/mysqld.sock
     #    - openSUSE/SLE  /var/run/mysql/mysql.sock:/var/run/mysqld/mysqld.sock
     #    - Debian/Ubuntu /var/run/mysqld:/var/run/mysqld
-    #- /var/run/mysqld:/var/run/mysqld
+    - /var/run/mysqld:/var/run/mysqld
     # private CA so egroupware can validate your certificate to talk to Collabora or Rocket.Chat
     # multiple certificates (eg. a chain) have to be single files in a directory, with one named private-ca.crt!
     #- /etc/egroupware-docker/private-ca.crt:/usr/local/share/ca-certificates/private-ca.crt:ro
-    #environment:
+    environment:
     # setting a default language for a new installation
     #- LANG=de
     # MariaDB/MySQL host to use: for host database (socket bind-mounted into container) use "localhost"
-    #- EGW_DB_HOST=localhost
+    - EGW_DB_HOST=localhost
     # for internal db service you should to specify a root password here AND in db service
     # a database "egroupware" with a random password is created for you on installation (password is stored in header.inc.php in data directory)
     #- EGW_DB_ROOT=root
@@ -70,10 +70,10 @@
     #- "my.host.name:ip-address"

   # to use the database on the host, uncomment all the following settings to disable the internal db service
-  #db:
-  #  image: busybox
-  #  entrypoint: /bin/true
-  #  restart: "no"
+  db:
+    image: busybox
+    entrypoint: /bin/true
+    restart: "no"

   # push server using phpswoole
   #push:
EOF
    # openSUSE/SLE update from before 19.1
    if [ -d /var/run/mysql ]
    then
      sed -i 's|- /var/run/mysqld.*|- /var/run/mysql/mysql.sock:/var/run/mysqld/mysqld.sock|g' docker-compose.override.yml
    fi
    # RHEL/CentOS update from before 19.1
    if [ -d /var/lib/mysql/mysql.sock ]
    then
      sed -i 's|- /var/run/mysqld.*|- /var/lib/mysql/mysql.sock:/var/run/mysqld/mysqld.sock|g' docker-compose.override.yml
    fi
  }
}

# case 3: new installation
# still no docker-compose.override.yml --> create it from latest-docker-compose.override.yml
test -f docker-compose.override.yml || cp latest-docker-compose.override.yml docker-compose.override.yml

# we also need to add websocket proxy to apache on the host (in front of regular proxy!)
grep -q "required for push" apache.conf || \
  sed -i apache.conf \
      -e 's|^ProxyPass /egroupware/|# required for push / websocket\nRewriteEngine on\nRewriteCond %{HTTP:Upgrade} websocket [NC]\nRewriteCond %{HTTP:Connection} upgrade [NC]\nRewriteRule /egroupware/push ws://127.0.0.1:8080/egroupware/push [P]\nProxyPass /egroupware/|'

# new install: create .env file with MariaDB root password
test -f .env || echo -e "# MariaDB root password\nEGW_DB_ROOT_PW=$(openssl rand -hex 16)\n" > .env

# remove egroupware container, in case 20.1+ update was run by watchtower and container lacks sessions volume
docker-compose stop
docker-compose rm -f egroupware

# check and fix path of sources volume: /var/lib/docker/volumes/egroupware-docker_sources
# Ubuntu 18.04 and openSUSE 15.1 skips the dash: /var/lib/docker/volumes/egroupwaredocker_sources
ls -1d /var/lib/docker/volumes/egroupware*docker_sources/_data/swoolepush || \
  docker-compose up -d egroupware
ls -1d /var/lib/docker/volumes/egroupware*docker_sources && \
test "$(ls -1d /var/lib/docker/volumes/egroupware*docker_sources)" = /var/lib/docker/volumes/egroupware-docker_sources || {
  grep "^volumes:" docker-compose.override.yml ||
    sed -e 's|^#volumes:|volumes:|' -i docker-compose.override.yml
  sed -i docker-compose.override.yml \
      -e "s|^volumes:|volumes:\n  # fix volume directory eg. for Ubuntu 18.04\n  sources-push:\n    driver_opts:\n      type: none\n      o: bind\n      device: $(ls -1d /var/lib/docker/volumes/egroupware*docker_sources)/_data/swoolepush\n|"
  docker volume rm -f egroupwaredocker_sources-push || true
}
