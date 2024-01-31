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
def_pkg mpc "1.3.1" "http://ftpmirror.gnu.org/mpc/mpc-#:ver:#.tar.gz" "ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8"
def_pkg musl "1.2.4" "http://musl.libc.org/releases/musl-#:ver:#.tar.gz" "7a35eae33d5372a7c0da1188de798726f68825513b7ae3ebe97aaaa52114f039"
def_pkg mpfr "4.2.1" "http://ftpmirror.gnu.org/mpfr/mpfr-#:ver:#.tar.xz" "277807353a6726978996945af13e52829e3abd7a9a5b7fb2793894e18f1fcbb2"
def_pkg isl "0.26" "http://libisl.sourceforge.io/isl-#:ver:#.tar.xz" "a0b5cb06d24f9fa9e77b55fabbe9a3c94a336190345c2555f9915bb38e976504"
def_pkg gmp "6.3.0" "http://ftpmirror.gnu.org/gmp/gmp-#:ver:#.tar.xz" "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"
def_pkg pkgconf "2.0.3" "http://distfiles.dereferenced.org/pkgconf/pkgconf-#:ver:#.tar.xz" "cabdf3c474529854f7ccce8573c5ac68ad34a7e621037535cbc3981f6b23836c"
def_pkg binutils "2.41" "http://ftpmirror.gnu.org/binutils/binutils-#:ver:#.tar.xz" "ae9a5789e23459e59606e6714723f2d3ffc31c03174191ef0d015bdf06007450"
def_pkg gcc "13.2.0" "http://ftpmirror.gnu.org/gcc/gcc-#:ver:#/gcc-#:ver:#.tar.xz" "e275e76442a6067341a27f04c5c6b83d8613144004c0413528863dc6b5c743da"

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
        --no-checkhash) unset verify_hash; shift ;;

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
[ -d "$CCBROOT/out/${bname:-ccb-$CPU_NAME}" ] && {
    i="2"
    while [ -d "$CCBROOT/out/${bname:-ccb-$CPU_NAME}.$i" ]; do
        i="$((i+1))"
    done
    export bdir="$CCBROOT/out/${bname:-ccb-$CPU_NAME}.$i"
} || {
    export bdir="$CCBROOT/out/${bname:-ccb-$CPU_NAME}"
}

# decide whether to say job or jobs
[ "$JOBS" -ne 1 ] && jsuf="threads" || jsuf="thread"

# ------------------------------------------------------------------------------

# make options
export MAKEOPTS="INFO_DEPS= infodir= ac_cv_prog_lex_root=lex.yy MAKEINFO=false -j$JOBS"

# print the starting status message
[ "$verbosity" != "silent" ] && printf "Starting build for $CPU_NAME/musl (${bdir##$CCBROOT/}) with $JOBS $jsuf\n" >&2

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
    usr/share \
    usr/src

# create symlinks
for i in bin lib lib32; do
    run ln -sf usr/$i $i
done

# change to usr
run cd "$bdir/usr"

# symlink local to its parent
run ln -sf . local

# symlink the build target to its parent
run ln -sf . "$TARGET"

# cd to the source dir
run cd "$bdir/usr/src"

# unpack and patch packages
[ "$use_pkgconf" = "y" ] && prep_pkg pkgconf
prep_pkg mpc
prep_pkg musl
prep_pkg mpfr
prep_pkg isl
prep_pkg gmp
prep_pkg binutils
prep_pkg gcc

# Step 1: install musl headers
# ------------------------------------------------------------------------------
printstatus "Installing musl headers"

# cd to the musl build dir
run cd "$pkg_musl_dirname"

# do tha thang
run make $MAKEOPTS ARCH="$MUSL_ARCH" DESTDIR="$bdir" prefix="/usr" install-headers


# Step 2: build binutils
# ------------------------------------------------------------------------------


# we're finished!
# ------------------------------------------------------------------------------

# get the end timestamp
[ "$timestamping" = "y" ] && {
    get_timestamp end
}

printf "Successfully built for $CPU_NAME/musl (${bdir##$CCBROOT/})${end_time:+ in $(fmt_timestamp $(diff_timestamp "$start_time" "$end_time"))} ${download_time:+($(fmt_timestamp "$download_time") spent downloading)}\n" >&2
