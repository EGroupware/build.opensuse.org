#!/bin/bash

cd $(dirname $0)

echo -n "EPL Repo User: "
read USER
echo -n "EPL Password:  "
read -s PASSWORD

docker login -u "$USER" -p "$PASSWORD" download.egroupware.org && {
	sed -e 's|image: egroupware/egroupware:latest|image: download.egroupware.org/egroupware/epl:latest|g' \
		-e "s|#\?- REPO_USER=.*|- REPO_USER='$USER'|g" \
		-e "s|#\?- REPO_PASSWORD=.*|- REPO_PASSWORD='$PASSWORD'|g" \
		-i docker-compose.yml

	echo "Updated $(dirname $0)/docker-compose.yml with following changes:"
	egrep '    image:.*egroupware|- REPO_' docker-compose.yml

	docker-compose up -d
}