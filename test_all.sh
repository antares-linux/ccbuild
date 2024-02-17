#!/bin/sh

# Copyright (C) 2024 Andrew Blue <andy@antareslinux.org>
#
# Distributed under the terms of the MIT license.
# See the LICENSE file for more information.

# test all builds

# check if the stuff is there
[ -r "$PWD/build.sh" ] || exit 1
[ -r "$PWD/util.sh" ] || exit 1
[ -d "$PWD/arch" ] || exit 1

# try to get the arch list
targets="$($PWD/build.sh --targets)" || exit 1
cjobs="$(nproc)"

# exit if it's empty
[ -n "$targets" ] || exit 1

# make a log dir
mkdir -p "$PWD/logs" || exit 1

# flags
printf "${@:+additional flags: $@\n}"

# for loop
for t in $targets; do
    eval "\"$PWD/build.sh\" -C --allow-root --log=\"$PWD/logs/build-$t.log\" -j${cjobs:-1} -p $t $@ >/dev/null 2>&1" >/dev/null 2>&1 && {
        printf "$t \033[1;32mworks\033[0m\n"
    } || {
        printf "$t \033[1;31mdoesn't work\033[0m\n"
    }
done
