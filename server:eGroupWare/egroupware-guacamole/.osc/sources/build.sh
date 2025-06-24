#!/bin/bash

VERSION=${1:-1.6.0.$(date +%Y%m%d)}
PACKAGE=egroupware-guacamole
GITURL=https://github.com/EGroupware/guacamole.git
BUILD=/tmp/$PACKAGE-build-root
OUTPUTDIR=$(dirname $0)
[[ $OUTPUTDIR = /* ]] || OUTPUTDIR=$PWD/${OUTPUTDIR#./}
TAROPTS="--uid 0 --gid 0 --no-xattrs --exclude .git -cvzf"


rm -rf $BUILD $OUTPUTDIR/$PACKAGE-*.tar.gz
mkdir -p $BUILD

cd $BUILD

git clone $GITURL $PACKAGE-$VERSION

(cd $PACKAGE-$VERSION; tar $TAROPTS $OUTPUTDIR/$PACKAGE-$VERSION.tar.gz .)

sed -e "s/^Version:.*/Version: $VERSION/g" \
    -e "s/$PACKAGE-.*.tar.gz/$PACKAGE-$VERSION.tar.gz/g" \
    -i "" $OUTPUTDIR/$PACKAGE.dsc

cd $OUTPUTDIR
osc addremove
osc status
