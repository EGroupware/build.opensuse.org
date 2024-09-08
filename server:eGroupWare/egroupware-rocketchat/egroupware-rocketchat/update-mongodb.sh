#!/bin/bash
############################################################################################################
###
### Script to update Rocket.Chat's MongoDB to a given version
###
### Usage: ./update-mongodb.sh <version>
###
### This with run the following steps:
### 1. check currently running MongoDB version is in docker-compose.override.yml
### 2. stop rocketchat container
### 3. dump current mongodb
### 4. stop mongodb and clear it's volume
### 5. update docker-compose.override.yml with desired version and start it again
### 6. restore the dump
### 7. start rocketchat container again
###
### The MongoDB version must be overriden for service mongo AND mongo-init-replica!
###
### MongoDB Upgrade Path: in general you can only upgrade to the next major version (eg. 4.0 to 4.2)
### 4.0 can only upgrade to 4.2, but requires --smallfiles --storageEngine=mmapv1 to be removed from command
### 4.2 can only upgrade to 4.4, AFTER setting FeatureCompatibilityVersion to "4.2": db.adminCommand( { setFeatureCompatibilityVersion: "4.2" } )
### 4.4 can only upgrade to 5.0, AFTER setting FeatureCompatibilityVersion to "4.4": db.adminCommand( { setFeatureCompatibilityVersion: "4.4" } )
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

# getting current mongodb major version
current=$(docker ps|grep mongo:|sed 's/^[0-9a-f]\{12,\} \{1,\}mongo:\([45]\.[0246]\).*$/\1/g')
echo $current | grep -qe '^[456]\.[0246]$' || {
  echo "$(basename $0): Could NOT determine current version of MongoDB, maybe MongoDB container is not running!"
  exit 1
}
echo "Currently running MongoDB version $current"
test $# -eq 1 && echo $1 | grep -qe '^[456]\.[0246]$' || {
  echo "Usage: $(basename $0) <version>"
  echo "  <version> MongoDB major version eg. 5.0, must be bigger then current version $current"
  exit 1
}
new=$1

if (( ${current//./} >= ${new//./} ))
then
  echo "Usage: $(basename $0) <version>"
  echo "Current MongoDB version '$current' is already equal or bigger then requested version '$new' --> aborting"
  # return success, as we are already on the given or a newer version
  exit 0
fi

# MongoDB updates can only update to the next major version / can NOT skip a major version
final=$new
case $current in
  4.0)
    new=4.2
    # update_overwrite always sets --storageEngine=wiredTiger/
    restore_extra_args="--noIndexRestore"
    ;;
  4.2)
    new=4.4
    ;;
  4.4)
    new=5.0 # requires RC 4.0
    ;;
  # MongoDB 6.0 no longer has mongo command, just new mongosh not supported by our mongo-init-replica!
  #5.0)
  #  new=6.0 # requires RC 6.x
  #  ;;
  *)
    echo "Update from MongoDB version '$current' to '$new' is NOT (yet) supported --> aborting";
    exit 1
esac

# set current version for FeatureCompatibility, as that's required for the update
docker exec rocketchat-mongo mongo --eval "db.adminCommand( { setFeatureCompatibilityVersion: \"$current\" } )"

# check new MongoDB version by pulling it
docker pull mongo:$new || {
  echo "Invalid / non-existing MongoDB version '$new' --> aborting"
  exit 1
}

# update docker-compose.override with given MongoDB version and update command to use --storageEngine=wiredTiger/
update_override() {
  # sed inplace for Linux and MacOS
  if uname -a | grep -q Darwin
  then
    sed_inplace="sed -i ''"
  else
    sed_inplace="sed -i"
  fi

  file=docker-compose.override.yml
  [ -f $file ] || {
    echo "No docker-compose.override.yml: creating an empty one"
    echo -e "version: '3'\n\nservices:" > $file
  }
  # check if we have a mongo service
  if grep -q '^ *mongo:' $file
  then
    # check if mongo service has an image set
    if grep -q '^ *image: \?mongo:.*' $file
    then
      # modify image
      $sed_inplace "s/^\( *\)image: *mongo:.*/\\1image: mongo:$1/g" $file
    else
      # add image
      echo -e "\n    image: mongo:$1" >> $file
    fi
  else
    # no mongo service --> add it
    echo -e "\n  mongo:\n    image: mongo:$1" >> $file
  fi

  # update mongod command: no more --smallfile and --storageEngine=mmapv1
  if grep -q '^ *command: *mongod' $file
  then
    $sed_inplace 's/\(^ *command: *mongod\).*$/\1 --oplogSize 128 --replSet rs0 --storageEngine=wiredTiger/' $file
  else
    echo "    command: mongod --oplogSize 128 --replSet rs0 --storageEngine=wiredTiger" >> $file
  fi

  # check if we have NO mongo-init-replica service (if we have one, it's image has been patched above)
  if grep -q '^ *mongo-init-replica:' $file
  then
    echo > /dev/null
  else
    # no mongo-init-replica service --> add it
    echo -e "\n\n  mongo-init-replica:\n    image: mongo:$1" >> $file
  fi
  echo "Updated mongo image in $file to $new"
}

# stop RC before dumping MongoDB
echo "Stopping Rocket.Chat"
$COMPOSE stop rocketchat

# first try to create a dump, without it we can't do anything
archive="/dump/rocketchat-$current-$(date '+%Y%m%d%H%I%S').tar.gz"
archive_host="/var/lib/egroupware/default/rocketchat$archive"
dumpcmd="mongodump --uri mongodb://localhost/rocketchat --gzip --archive=$archive"
echo "dumping MongoDB to $archive_host ($dumpcmd)"
docker exec rocketchat-mongo $dumpcmd
if [ ! -s $archive_host ]
then
  echo "Could NOT dump MongoDB to file $archive_host (docker exec rocketchat-mongo $dumpcmd) --> aborting"
  exit 1
fi

# update mongo version in docker-compose.override.yml
echo "Updating /etc/egroupware-rocketchat/docker-compose.override.yml with new MongoDB version"
update_override $new

# stop and delete mongo container, remove mongo db volume
echo "Deleting current MongoDB container and volume"
$COMPOSE down
docker volume rm -f egroupware-rocketchat_mongo

# start new MongoDB version and create new replica set
echo "Starting new MongoDB version"
$COMPOSE up -d mongo-init-replica
# wait for it to finish
docker logs -f egroupware-rocketchat_mongo-init-replica_1

# restore database dump
echo "Restoring MongoDB dump"
docker exec rocketchat-mongo mongorestore --uri mongodb://localhost/rocketchat --drop --gzip --archive=$archive $restore_extra_args
[ -z "$restore_after_cmd" ] || docker exec rocketchat-mongo $restore_after_cmd

echo "MongoDB successfully updated to version $new"

# if we are not yet on the desired version, run the next update
if [ "$new" != "$final" ]
then
  exec $0 $final
fi