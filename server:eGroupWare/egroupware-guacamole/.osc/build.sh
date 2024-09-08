#!/bin/bash

VERSION=${1:-1.5.5.$(date +%Y%m%d)}
PACKAGE=egroupware-guacamole
GITURL=https://github.com/EGroupware/guacamole.git
BUILD=/tmp/$PACKAGE-build-root
OUTPUTDIR=$(dirname $0)
[[ $OUTPUTDIR = /* ]] || OUTPUTDIR=$PWD/${OUTPUTDIR#./}
TAROPTS="--uid 0 --gid 0 -cvzf"


rm -rf $BUILD $OUTPUTDIR/$PACKAGE-*.tar.gz
mkdir -p $BUILD

cd $BUILD

git clone $GITURL $BUILD/$PACKAGE-$VERSION

tar $TAROPTS $OUTPUTDIR/$PACKAGE-$VERSION.tar.gz $PACKAGE-$VERSION 

sed -e "s/^Version:.*/Version: $VERSION/g" \
    -e "s/$PACKAGE-.*.tar.gz/$PACKAGE-$VERSION.tar.gz/g" \
    -i "" $OUTPUTDIR/$PACKAGE.dsc

cd $OUTPUTDIR
osc addremove
osc status