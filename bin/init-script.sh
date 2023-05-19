#!/bin/bash

# Initialize CI script for next Ibexa DXP version base on previous one.

if [ ! -n "$1" ]
then
    echo "Usage: `basename $0` <prev-version> <next-version>"
    echo "Example: `basename $0` 4.5 4.6"
    exit 1
fi

PREV_VERSION=$1;
NEXT_VERSION=$2;

cp -R "bin/$PREV_VERSION.x-dev" "bin/$NEXT_VERSION.x-dev"
