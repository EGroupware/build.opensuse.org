#!/bin/bash

docker logs -f --tail=100 egroupware-nginx 2>&1 | sed "s/PHP message/\\$(echo -e '\n\r')PHP message/g"
