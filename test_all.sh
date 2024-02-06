#!/bin/sh

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

# for loop
for t in $targets; do
    "$PWD/build.sh" --allow-root --log="$PWD/logs/build-$t.log" -j${cjobs:-1} -p $t >/dev/null 2>&1 && {
        printf "$t works\n"
    } || {
        printf "$t doesn't work\n"
    }
done
