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

# define packages
def_pkg mpc "1.3.1" "http://ftpmirror.gnu.org/mpc/mpc-#:ver:#.tar.gz" "shasum"
def_pkg musl "1.2.4" "http://musl.libc.org/releases/musl-#:ver:#.tar.gz" "shasum"
def_pkg mpfr "4.2.1" "http://ftpmirror.gnu.org/mpfr/mpfr-#:ver:#.tar.xz" "shasum"
def_pkg isl "0.26" "http://libisl.sourceforge.io/isl-#:ver:#.tar.xz" "shasum"
def_pkg gmp "6.3.0" "http://ftpmirror.gnu.org/gmp/gmp-#:ver:#.tar.xz" "shasum"
def_pkg pkgconf "2.0.3" "http://distfiles.dereferenced.org/pkgconf/pkgconf-#:ver:#.tar.xz" "shasum"
def_pkg binutils "2.41" "http://ftpmirror.gnu.org/binutils/binutils-#:ver:#.tar.xz" "shasum"
def_pkg gcc "13.2.0" "http://ftpmirror.gnu.org/gcc/gcc-#:ver:#/gcc-#:ver:#.tar.xz" "shasum"

# environment variables
export CFLAGS="-pipe -Os -g0 -ffunction-sections -fdata-sections -fmerge-all-constants"
export CXXFLAGS="-pipe -Os -g0 -ffunction-sections -fdata-sections -fmerge-all-constants"
export LDFLAGS="-s -Wl,--gc-sections,-s,-z,norelro,-z,now,--hash-style=sysv,--build-id=none,--sort-section,alignment"
export JOBS="1"

# by default, all output is printed; this will slow down the
# script slightly but it's a requirement for debugging
verbosity="normal"

# (internal, no opt for now)
# whether to use [l]ong or [s]hort suffixes for time units
unitsize="l"

# whether to verify checksums
verify_hash="y"

# whether to download and build pkgconf
#use_pkgconf="y"

# ------------------------------------------------------------------------------

# parse command-line arguments
while [ "$#" -gt 0 ]; do
    # case statement (lol useless comment but my OC wants one to be here)
    case "$1" in
        # allow the root user to use ccbuild
        --allow-root) allow_root="y"; shift ;;

        # disable sha256 hash checking
        --no-checksum) unset verify_hash; shift ;;

        # clean CCBROOT
        --clean) full_clean="y"; shift ;;

        # clean the build after it's finished
        -C|--cleanup) build_post_cleanup="y"; shift ;;

        # disable post-build cleaning
        --no-cleanup) unset build_post_cleanup; shift ;;

        # print the command line to stdout
        -c|--cmdline) printcmdline="y"; shift ;;

        # don't print the command line to stdout (default)
        --no-cmdline) unset printcmdline; shift ;;

        # print help
        --help) print_help; exit ;;

        # input a custom job number
        -j|--jobs)            [ "$2" -le 1024 >&- 2>&- ] && export JOBS="$2"; shift 2 ;;
        -j*)            [ "${1##-j}" -le 1024 >&- 2>&- ] && export JOBS="${1##-j}"; shift ;;
        --jobs=*)  [ "${1##--jobs=}" -le 1024 >&- 2>&- ] && export JOBS="${1##--jobs=}"; shift ;;

        # pipe compiler/configure script output to ccbuild.log
        -l|--log) buildlog="$CCBROOT/ccbuild.log"; :>"$buildlog"; shift ;;

        # don't pipe compiler/configure script output to ccbuild.log (default)
        --no-log) unset buildlog; shift ;;

        # specify a custom name for the build other than "ccb-ARCH.NUM"
        -n|--name) export bname="$2";            shift 2 ;;
        -n*)       export bname="${1##-n}";      shift ;;
        --name=*)  export bname="${1##--name=}"; shift ;;

        # whether to download and use pkgconf
        -p|--pkgconf) use_pkgconf="y"; shift ;;
        --no-pkgconf) unset use_pkgconf; shift ;;

        # quieter, terse output (status msgs)
        -q|--quieter) verbosity="quieter"; shift ;;

        # completely silent
        -s|--silent) verbosity="silent"; shift ;;

        # print a list of the available architectures and exit
        --targets) list_targets; exit ;;

        # timestamp the build process
        -t|--timestamping) timestamping="y"; shift ;;

        # don't timestamp the build process (default)
        --no-timestamping) unset timestamping; shift ;;

        # verbose (default) output
        -v|--verbose) verbosity="normal"; shift ;;

        # set the target name
        *) [ -z "$target" ] && target="${1%%/}"; shift ;;
    esac
done

# warn the user about running as root
[ "$allow_root" = "y" ] || {
    [ "${EUID:-${UID:-$(id -u)}}" -ne 0 >/dev/null 2>&1 ] || {
        printf "${0##*/}: error: Running this script with root privileges is not recommended. Run \`$0 --allow-root\` to allow this.\n" >&2
        exit 1
    }
}


# clean up the script root if desired
[ "$full_clean" = "y" ] && {
    run rm -rf "$CCBROOT/build" "$CCBROOT/out" "$CCBROOT/cache" "$CCBROOT/ccbuild.log"
    exit
}

# try to load the architecture build flags
[ -r "$CCBROOT/arch/$target.conf" ] && {
    . "$CCBROOT/arch/$target.conf"
} || {
    [ -n "$target" ] && {
        printf "${0##*/}: error: Invalid option or target $target\n" >&2
        exit 1
    } || {
        printf "${0##*/}: error: No target specified. Run \`$0 --help\` for more information.\n" >&2
        exit 1
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

# timestamping setup
[ "$timestamping" = "y" ] && {
    # these commands are required for timestamping
    require_command date bc

    # check whether nanoseconds work
    [ "$(date +%N | wc -c 2>/dev/null)" = "10" ] && has_ns="y"

    # get the beginning
    get_timestamp start
}

# create the build dir
run mkdir -p "$CCBROOT/cache"

# cd to the build directory
run cd "$CCBROOT/cache"

# download packages
[ "$use_pkgconf" = "y" ] && get_pkg pkgconf
get_pkg mpc
get_pkg musl
get_pkg mpfr
get_pkg isl
get_pkg gmp
get_pkg binutils
get_pkg gcc

# print a status message that the dir structure for the toolchain is being made
printstatus "Creating directory structure"

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

# get the end timestamp
[ "$timestamping" = "y" ] && {
    get_timestamp end
}

printf "success: Successfully built for $FARCH/musl (${bdir##$CCBROOT/})${end_time:+ in $(fmt_timestamp $(diff_timestamp "$start_time" "$end_time"))} ${download_time:+($(fmt_timestamp "$download_time") spent downloading)}\n" >&2
