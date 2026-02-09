#!/bin/bash

source /etc/egroupware-docker/.env
[ -t 0 -a -t 1 ] && TERMINAL=-t
exec docker exec -i $TERMINAL egroupware-db $(basename $0 .sh|sed 's/mysql/mariadb/') -p"$EGW_DB_ROOT_PW" egroupware "$@"