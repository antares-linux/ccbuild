#!/bin/sh

# fields are separated by '/' so each dir/file in a path is operated on
_IFS="$IFS"
IFS="/"

# cd to the cwd of the script
for i in $0; do
    [ -d "$i" ] && cd "$i"
done

# restore field separator & save script cwd
IFS="$_IFS"
export CCBROOT="$PWD"

# exit if ccbroot can't be set
[ -n "$CCBROOT" ] || {
    printf "${0##*/}: error: CCBROOT can't be set\n" >&2
    exit 1
}

# exit if ccbroot isn't set correctly
[ -r "$CCBROOT/${0##*/}" ] || {
    printf "${0##*/}: error: CCBROOT set incorrectly\n" >&2
    exit 1
}

# ensure util.sh exists
[ -r "$CCBROOT/util.sh" ] || {
    printf "${0##*/}: error: util.sh: No such file or directory\n" >&2
    exit 1
}

# load utility functions (these are separated for cleanliness)
. "$CCBROOT/util.sh"

# environment variables
export CFLAGS="-pipe -Os -g0 -ffunction-sections -fdata-sections -fmerge-all-constants"
export CXXFLAGS="-pipe -Os -g0 -ffunction-sections -fdata-sections -fmerge-all-constants"
export LDFLAGS="-s -Wl,--gc-sections,-s,-z,norelro,-z,now,--hash-style=sysv,--build-id=none,--sort-section,alignment"
export JOBS="1"

# by default, all output is printed; this will slow down the
# script slightly but it's a requirement for debugging
verbosity="normal"

# ------------------------------------------------------------------------------

# parse command-line arguments
while [ "$#" -gt 0 ]; do
    # case statement (lol useless comment but my OC wants one to be here)
    case "$1" in
        # clean CCBROOT
        --clean) full_clean="y"; shift ;;

        # clean the build after it's finished
        -C|--cleanup) build_post_cleanup="y"; shift ;;

        # print the command line to stdout
        -c|--cmdline) printcmdline="y"; shift ;;

        # print help
        --help) print_help; exit ;;

        # input a custom job number
        -j|--jobs)            [ "$2" -le 1024 >&- 2>&- ] && export JOBS="$2"; shift 2 ;;
        -j*)            [ "${1##-j}" -le 1024 >&- 2>&- ] && export JOBS="${1##-j}"; shift ;;
        --jobs=*)  [ "${1##--jobs=}" -le 1024 >&- 2>&- ] && export JOBS="${1##--jobs=}"; shift ;;

        # pipe compiler/configure script output to FILE instead of /dev/null
        -l|--log) buildlog="$CCBROOT/ccbuild.log"; :>"$buildlog"; shift ;;

        # specify a custom name for the build other than "ccb-ARCH.NUM"
        -n|--name) export bname="$2";            shift 2 ;;
        -n*)       export bname="${1##-n}";      shift ;;
        --name=*)  export bname="${1##--name=}"; shift ;;

        # quieter, terse output (status msgs)
        -q|--quieter) verbosity="quieter"; shift ;;

        # completely silent
        -s|--silent) verbosity="silent"; shift ;;

        # verbose (default) output
        -v|--verbose) verbosity="normal"; shift ;;

        # print a list of the available architectures and exit
        --targets) list_targets; exit ;;

        # set the target name
        *) target="${1%%/}"; shift ;;
    esac
done

# clean up the script root if desired
[ "$full_clean" = "y" ] && {
    run rm -rf "$CCBROOT/build" "$CCBROOT/out" "$CCBROOT/cache" "$CCBROOT/ccbuild.log"
    exit
}

# try to load the architecture build flags
[ -r "$CCBROOT/arch/$target.conf" ] && {
    . "$CCBROOT/arch/$target.conf"
} || {
    [ -n "$1" ] && {
        printf "${0##*/}: error: Invalid target $target\n" >&2
        exit 2
    } || {
        printf "${0##*/}: error: No target specified. Run \`$0 --help\` for more information.\n" >&2
        exit 3
    }
}

# set the build directory for a new toolchain
[ -d "$CCBROOT/out/${bname:-ccb-$FARCH}" ] && {
    i="2"
    while [ -d "$CCBROOT/out/${bname:-ccb-$FARCH}.$i" ]; do
        i="$((i+1))"
    done
    export bdir="$CCBROOT/out/${bname:-ccb-$FARCH}.$i"
} || {
    export bdir="$CCBROOT/out/${bname:-ccb-$FARCH}"
}

# decide whether to say job or jobs
[ "$JOBS" -ne 1 ] && jsuf="threads" || jsuf="thread"

# ------------------------------------------------------------------------------

# print the starting status message
[ "$verbosity" != "silent" ] && printf "Starting build for $FARCH/musl (${bdir##$CCBROOT/}) with $JOBS $jsuf\n" >&2

# print a status message that the dir structure for the toolchain is being made
[ "$verbosity" = "quieter" ] && [ "$printcmdline" != "y" ] && printf "Creating directory structure\n" >&2

# create the build dir
run mkdir -p "$bdir"

# cd to the build directory
run cd "$bdir"

# create dirs
run mkdir -p \
    usr/bin \
    usr/lib \
    usr/lib32 \
    usr/include \
    usr/sbin \
    usr/share \
    usr/src

# create symlinks
for i in bin sbin lib lib32; do
    run ln -sf usr/$i $i
done

# symlink local to its parent
run cd "$bdir/usr"
run ln -sf . local

# ------------------------------------------------------------------------------

printf "success: Successfully built for $FARCH/musl (${bdir##$CCBROOT/})\n" >&2
