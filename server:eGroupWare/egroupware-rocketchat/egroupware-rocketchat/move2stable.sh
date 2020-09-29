#!/bin/bash

# make sure we have jq
jq=$(which jq)
[ -z "$jq" -o ! -x "$jq" ] && {
  jq=/usr/local/bin/jq
  curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 > $jq
  chmod +x $jq
}
# check if current version not already passed our stable version in docker-compose (or user set an override, but not "latest")
rc_info_url=http://localhost:3000/rocketchat/api/info
current_version=$(curl $rc_info_url 2>/dev/null | jq .version | cut -d'"' -f2)
override_path=/etc/egroupware-rocketchat/docker-compose.override.yml
override_version=$(egrep  '^ +image: rocketchat/rocket.chat:' $override_path | cut -d: -f3)
tag_url="https://quay.io/api/v1/repository/egroupware/rocket.chat/tag/?onlyActiveTags=true"
image_id=$(curl -H X-Request-With:curl $tag_url 2>/dev/null | jq '.tags[] | select(.name == "stable") | .image_id')
stable_version=$(curl -H X-Request-With:curl $tag_url 2>/dev/null | jq ".tags[] | select(.image_id == $image_id) | .name" | egrep -v '(stable|latest)' | cut -d'"' -f2)

echo "Rocket.Chat versions: current: $current_version, override: $override_version, stable: $stable_version"

# compare 2 versions for less or equal
verlte() {
    [  "$1" = "`echo -e "$1\n$2" | sort -V | head -n1`" ]
}

[ -n "$override_version" -a "$override_version" != "latest" ] || [ -n "$current_version" ] && verlte "$current_version" "$stable_version" && {
  echo "Current version $current_version is less or equal to stable version $stable_version --> use stable version now"
  # remove evtl. set latest tag in override
  sed -e 's|^ *image: rocketchat/rocket.chat:latest|    #image: rocketchat/rocket.chat:latest|g' \
    -i $override_path
} || {
  echo "Current version $current_version already passed stable version $stable_version --> put rocketchat/rocket.chat:latest in $override_path"
  sed -e 's|^.*image: rocketchat/rocket.chat:.*|    image: rocketchat/rocket.chat:latest|g' \
    -i $override_path
}
