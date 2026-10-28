#!/bin/bash
# Start a Samba server next to the installed egroupware-docker, to test SMB/CIFS access from the egroupware container (SMB=1 of run-test.sh).
# The server is reachable in the compose network under the FQDN fileserver.corp.test only, so the short name "fileserver" needs the search domain
# corp.test (ticket #127001: short names stopped working with the Alpine based image), also as fileserver.sub.corp.test, the checks are in verify-smb.sh.
# Runs as root inside the test machine after the egroupware-docker install.
set -euxo pipefail
NET=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' egroupware)
docker rm -f smb-server >/dev/null 2>&1 || true
docker run -d --name smb-server --network "$NET" --network-alias fileserver.corp.test --network-alias fileserver.sub.corp.test \
	-e USER=egw -e PASS=Secret123 -e NAME=data dockurr/samba
# wait until smbd is up
for i in $(seq 1 60); do docker logs smb-server 2>&1 | grep -q 'smbd version' && break; sleep 2; done
docker logs smb-server 2>&1 | tail -3
