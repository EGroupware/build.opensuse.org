#!/bin/bash

cd $(dirname $0)

echo -n "EPL Repo User: "
read USER
echo -n "EPL Password:  "
read -s PASSWORD
echo " "

# Debian 10 has curl not installed by default
$(which curl) || apt install -y curl

# test authentication first (if we have curl available)
[ -x "$(which curl)" -a $(curl -i --user "$USER:$PASSWORD" https://download.egroupware.org/repos/stylite-epl/ 2>/dev/null|head -1|cut -d" " -f2) -eq 401 ] && {
	echo " "
	echo "Username or password wrong"
	exit
}

PASSWORD_PARAM="--password-stdin"
# docker on RHEL/CentOS 7 does NOT support --password-stdin
docker help login|grep -- $PASSWORD_PARAM >/dev/null || {
	PASSWORD_PARAM="--password $PASSWORD"
}

# if Docker config did not exist when watchtower container was started, it is created as empty directory --> remove it
[ -d ~/.docker/config.json ] && rm -rf ~/.docker/config.json

echo "$PASSWORD" | docker login -u "$USER" $PASSWORD_PARAM download.egroupware.org || {
	[ -x /usr/bin/docker-credential-secretservice ] || {
		echo "No /usr/bin/docker-credential-secretservice installed, don't know why docker login failed, maybe the user or password is wrong ..."
		exit 1
	}
	echo " "
	echo "You have /usr/bin/docker-credential-secretservice installed, which does not work on a server without graphical user-interface (X11)."
	echo -n "Should we remove it and try again (Y/n) "
	read answer
	if [ "$answer" = "n" ]
	then
		exit
	fi
	mv /usr/bin/docker-credential-secretservice /usr/bin/docker-credential-secretservice.disabled || {
		echo "Can not rename /usr/bin/docker-credential-secretservice to /usr/bin/docker-credential-secretservice.disabled"
		exit 1
	}
	echo "/usr/bin/docker-credential-secretservice renamed to /usr/bin/docker-credential-secretservice.disabled, retrying docker login ..."
	echo "$PASSWORD" | docker login -u "$USER" $PASSWORD_PARAM download.egroupware.org || {
		echo "Docker login still failing, maybe the user or password is wrong ..."
		exit 1
	}
}
sed -e 's|image: egroupware/egroupware:|image: download.egroupware.org/egroupware/epl:|g' \
	-e "/#\?- REPO_USER=.*/d" \
	-e "/#\?- REPO_PASS.*=.*/d" \
	-i docker-compose.override.yml

echo "Updated $(dirname $0)/docker-compose.override.yml with following changes:"
grep '    image:.*egroupware' docker-compose.override.yml

docker-compose up -d --force-recreate