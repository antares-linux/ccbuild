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
    printf -- "${0##*/}: error: CCBROOT can't be set\n" >&2
    exit 1
}

# exit if ccbroot isn't set correctly
[ -r "$CCBROOT/${0##*/}" ] || {
    printf -- "${0##*/}: error: CCBROOT set incorrectly\n" >&2
    exit 1
}

# ensure util.sh exists
[ -r "$CCBROOT/util.sh" ] || {
    printf -- "${0##*/}: error: util.sh: No such file or directory\n" >&2
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
def_pkg pkgconf "2.1.0" "http://distfiles.dereferenced.org/pkgconf/pkgconf-#:ver:#.tar.xz" "cabdf3c474529854f7ccce8573c5ac68ad34a7e621037535cbc3981f6b23836c"
def_pkg binutils "2.42" "http://ftpmirror.gnu.org/binutils/binutils-#:ver:#.tar.xz" "f6e4d41fd5fc778b06b7891457b3620da5ecea1006c6a4a41ae998109f85a800"
def_pkg gcc "13.2.0" "http://ftpmirror.gnu.org/gcc/gcc-#:ver:#/gcc-#:ver:#.tar.xz" "e275e76442a6067341a27f04c5c6b83d8613144004c0413528863dc6b5c743da"

# (internal, no opt for now)
# use [l]ong or [s]hort suffixes for time units
unitsize="l"

# verify checksums
verify_hash="y"

# clean the build after it's finished
#build_post_cleanup="y"

# print the command line to stdout
#printcmdline="y"

# shell/command to spawn the end of the build, but before post-build actions
#spawn_shell="${SHELL:-/bin/sh}"

# download and build pkgconf
#use_pkgconf="y"

# do timestamping
#timestamping="y"

# by default, all output is printed; this will slow down the
# script slightly but it's a requirement for debugging
verbosity="normal"

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
        -j|--jobs)            [ "$2" -le 1024 >&- 2>&- ] && jobs="$2"; shift 2 ;;
        -j*)            [ "${1##-j}" -le 1024 >&- 2>&- ] && jobs="${1##-j}"; shift ;;
        --jobs=*)  [ "${1##--jobs=}" -le 1024 >&- 2>&- ] && jobs="${1##--jobs=}"; shift ;;

        # pipe compiler/configure script output to ccbuild.log
        -l|--log) buildlog="$CCBROOT/ccbuild.log"; :>"$buildlog"; shift ;;
        -l*)      buildlog="${1##-l}"; :>"$buildlog"; shift ;;
        --log=*)  buildlog="${1##--log=}"; :>"$buildlog"; shift ;;

        # don't pipe compiler/configure script output to ccbuild.log (default)
        --no-log) unset buildlog; shift ;;

        # specify a custom name for the build other than "ccb-ARCH.NUM"
        -n|--name) bname="$2";            shift 2 ;;
        -n*)       bname="${1##-n}";      shift ;;
        --name=*)  bname="${1##--name=}"; shift ;;

        # whether to download and use pkgconf
        -p|--pkgconf) use_pkgconf="y"; shift ;;
        --no-pkgconf) unset use_pkgconf; shift ;;

        # quieter, terse output (status msgs)
        -q|--quieter) verbosity="quieter"; shift ;;

        # completely silent
        -s|--silent) verbosity="silent"; shift ;;

        # spawn a shell under the script's environment after the build finishes
        --shell) spawn_shell="${SHELL:-/bin/sh}"; shift ;;
        --no-shell) unset spawn_shell; shift ;;

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
        printf -- "${0##*/}: error: Running this script with root privileges is not recommended. Run \`$0 --allow-root\` to allow this.\n" >&2
        exit 1
    }
}

# clean up the script root if desired
[ "$full_clean" = "y" ] && {
    run rm -rf "$CCBROOT/build" "$CCBROOT/out" "$CCBROOT/cache" "$CCBROOT/ccbuild.log"
    exit
}

# export these variables
set -a

# try to load the architecture build flags
[ -r "$CCBROOT/arch/$target.conf" ] && {
    . "$CCBROOT/arch/$target.conf"
} || {
    [ -n "$target" ] && {
        printf -- "${0##*/}: error: Invalid option or target $target\n" >&2
        exit 1
    } || {
        printf -- "${0##*/}: error: No target specified. Run \`$0 --help\` for more information.\n" >&2
        exit 1
    }
}

# set the build directory for a new toolchain
[ -d "$CCBROOT/out/${bname:-ccb-$CPU_NAME}" ] && {
    i="2"
    while [ -d "$CCBROOT/out/${bname:-ccb-$CPU_NAME}.$i" ]; do
        i="$((i+1))"
    done
    bdir="$CCBROOT/out/${bname:-ccb-$CPU_NAME}.$i"
} || {
    bdir="$CCBROOT/out/${bname:-ccb-$CPU_NAME}"
}

# environment variables
CFLAGS="-pipe -Os -s -g0 -ffunction-sections -fdata-sections -fmerge-all-constants"
CXXFLAGS="-pipe -Os -s -g0 -ffunction-sections -fdata-sections -fmerge-all-constants"
LDFLAGS="-s -Wl,--gc-sections,-s,-z,now,--hash-style=sysv,--build-id=none,--sort-section,alignment"
JOBS="${jobs:-1}"
MAKEINFO="missing"
PATH="$bdir/bin:$PATH"
DESTDIR="$bdir"

# make/cmake command lines
MAKEOPTS="INFO_DEPS= ac_cv_prog_lex_root=lex.yy -j$JOBS"

# don't export any more variables implicitly
set +a


# Step 0: set up the environment
# ------------------------------------------------------------------------------

# semantic
[ "$JOBS" -ne 1 ] && jsuf="threads" || jsuf="thread"

# print the starting status message
[ "$verbosity" != "silent" ] && printf -- "Starting build for $CPU_NAME/musl (${bdir##$CCBROOT/}) with $JOBS $jsuf\n" >&2

# timestamping setup
[ "$timestamping" = "y" ] && {
    # these commands are required for timestamping
    require_command date bc

    # check whether nanoseconds work
    [ "$(date +%N)" != '%N' ] && has_ns="y"

    # get the beginning
    get_timestamp start
}

# create the build dir
run mkdir -p "$CCBROOT/cache"

# cd to the build directory
run cd "$CCBROOT/cache"

# the base toolchain
get_pkg mpc
get_pkg musl
get_pkg mpfr
get_pkg isl
get_pkg gmp
get_pkg binutils
get_pkg gcc

# optional
[ "$use_pkgconf" = "y" ] && get_pkg pkgconf

# print a status message that the dir structure for the toolchain is being made
printstatus "Creating directory structure"

# create the build dir
run mkdir -p "$bdir"

# cd to the build directory
run cd "$bdir"

# create dirs
run mkdir -p \
    bin \
    lib \
    lib32 \
    libexec \
    include \
    share \
    src \
    _tmp

# symlink usr to its parent (compatibility)
run ln -sf . usr

# symlink the build target to its parent
run ln -sf . "$TARGET"

# cd to the source dir
run cd "$bdir/src"

# unpack and patch packages
prep_pkg mpc
prep_pkg musl
prep_pkg mpfr
prep_pkg isl
prep_pkg gmp
prep_pkg binutils
prep_pkg gcc

# these as well
[ "$use_pkgconf" = "y" ] && prep_pkg pkgconf


# Step 1: install musl headers
# ------------------------------------------------------------------------------

# cd to the musl build dir
printstatus "Installing musl headers"
run cd "$pkg_musl_dirname"

# do tha thang
run make $MAKEOPTS ARCH="$MUSL_ARCH" DESTDIR="$bdir" prefix="" install-headers


# Step 2: build binutils
# ------------------------------------------------------------------------------

# create a build directory for binutils
printstatus "Configuring binutils-$pkg_binutils_version"
run mkdir "../build-binutils"
run cd "../build-binutils"

# configure binutils
run "../$pkg_binutils_dirname/configure" \
    --with-sysroot="/" \
    --with-build-sysroot="$bdir" \
    --prefix="" \
    --exec-prefix="" \
    --sbindir="/bin" \
    --datarootdir="/_tmp" \
    --target="$TARGET" \
    --with-pkgversion="ccbuild $pkg_binutils_version-cross-musl" \
    --with-boot-ldflags="$LDFLAGS" \
    --enable-default-hash-style="sysv" \
    --enable-default-pie \
    --enable-static-pie \
    --enable-relro \
    --disable-bootstrap \
    --disable-lto \
    --disable-multilib \
    --disable-werror \
    --disable-linker-build-id \
    --disable-dependency-tracking \
    --disable-rpath \
    $CPU_FLAGS


# compile binutils
printstatus "Compiling binutils-$pkg_binutils_version"
run make \
    $MAKEOPTS \
    all-binutils \
    all-gas \
    all-ld

# install binutils
printstatus "Installing binutils-$pkg_binutils_version"
run make \
    $MAKEOPTS \
    DESTDIR="$bdir" \
    install-strip-binutils \
    install-strip-gas \
    install-strip-ld

# remove redundant binaries to save space
cd "$bdir/bin"
run rm -rf \
    $TARGET-ld \
    ar \
    as \
    ld \
    ld.bfd \
    nm \
    objcopy \
    objdump \
    ranlib \
    readelf \
    strings \
    strip \

# link ld.bfd to ld
run ln -sf $TARGET-ld.bfd $TARGET-ld


# Step 3: build gcc
# ------------------------------------------------------------------------------

# symlink required libraries
run cd "$bdir/src/$pkg_gcc_dirname"
run ln -sf "../$pkg_gmp_dirname" "gmp"
run ln -sf "../$pkg_mpfr_dirname" "mpfr"
run ln -sf "../$pkg_mpc_dirname" "mpc"
run ln -sf "../$pkg_isl_dirname" "isl"

# create a build directory for gcc
printstatus "Configuring gcc-$pkg_gcc_version"
run mkdir "$bdir/src/build-gcc"
run cd "$bdir/src/build-gcc"

# configure gcc
run "../$pkg_gcc_dirname/configure" \
    --with-sysroot="/" \
    --with-build-sysroot="$bdir" \
    --prefix="" \
    --exec-prefix="" \
    --sbindir="/bin" \
    --datarootdir="/_tmp" \
    --target="$TARGET" \
    --with-pkgversion="ccbuild $pkg_gcc_version-cross-musl" \
    --with-boot-ldflags="$LDFLAGS" \
    --enable-languages=c,c++ \
    --enable-default-hash-style="sysv" \
    --enable-default-pie \
    --enable-static-pie \
    --enable-relro \
    --enable-libstdcxx=time=rt \
    --enable-initfini-array \
    --disable-bootstrap \
    --disable-lto \
    --disable-multilib \
    --disable-werror \
    --disable-dependency-tracking \
    --disable-rpath \
    --disable-libsanitizer \
    --disable-linker-build-id \
    $CPU_FLAGS

# compile gcc
printstatus "Compiling gcc-$pkg_gcc_version"
run make \
    $MAKEOPTS \
    all-gcc

# install gcc
printstatus "Installing gcc-$pkg_gcc_version"
run make \
    $MAKEOPTS \
    DESTDIR="$bdir" \
    install-strip-gcc

# remove redundant binaries to save space
cd "$bdir/bin"
run rm -rf \
    $TARGET-gcc \
    $TARGET-gcc-ar \
    $TARGET-gcc-nm \
    $TARGET-gcc-ranlib

# symlinks
run ln -sf $TARGET-ar $TARGET-gcc-ar
run ln -sf $TARGET-nm $TARGET-gcc-nm
run ln -sf $TARGET-ranlib $TARGET-gcc-ranlib
run ln -sf $TARGET-gcc-$pkg_gcc_version $TARGET-gcc
run ln -sf $TARGET-gcc $TARGET-cc
run ln -sf $TARGET-g++ $TARGET-c++


# Step 4: build libgcc-static
# ------------------------------------------------------------------------------

# move back to the gcc build dir
printstatus "Compiling libgcc-$pkg_gcc_version-static"
run cd "$bdir/src/build-gcc"

# compile gcc
run make \
    $MAKEOPTS \
    enable_shared=no \
    all-target-libgcc

# install gcc
printstatus "Installing libgcc-$pkg_gcc_version-static"
run make \
    $MAKEOPTS \
    DESTDIR="$bdir" \
    install-strip-target-libgcc

# cd to the library dir
cd "$bdir/lib"

# create links to libgcc objects in /lib (the linker/loader might not find them in the gcc subpath)
for i in gcc/$TARGET/$pkg_gcc_version/*.o gcc/$TARGET/$pkg_gcc_version/*.so gcc/$TARGET/$pkg_gcc_version/*.a; do
    [ -r "$i" ] && [ ! -r "${i##gcc/$TARGET/$pkg_gcc_version/}" ] && run ln -sf $i ${i##gcc/$TARGET/$pkg_gcc_version/}
done


# Step 5: build musl libc
# ------------------------------------------------------------------------------

# move to the musl build dir
printstatus "Configuring musl-$pkg_musl_version"
run cd "$bdir/src/$pkg_musl_dirname"

# configure musl
ARCH="$MUSL_ARCH" \
CC="$TARGET-gcc" \
CROSS_COMPILE="$TARGET-" \
LIBCC="$bdir/lib/libgcc.a" \
run ./configure \
    --target="$TARGET" \
    --host="$TARGET" \
    --prefix=""

# compile musl
printstatus "Compiling musl-$pkg_musl_version"
run make \
    $MAKEOPTS \
    AR="$TARGET-ar" \
    RANLIB="$TARGET-ranlib"

# install musl
printstatus "Installing musl-$pkg_musl_version"
run make \
    $MAKEOPTS \
    AR="$TARGET-ar" \
    RANLIB="$TARGET-ranlib" \
    DESTDIR="$bdir" \
    install-libs install-tools

# create links for the dynamic program loader
cd "$bdir/lib"

# unlink ld-musl-MUSL_ARCH.so.1
run rm -rf "ld-musl-$MUSL_ARCH.so.1"

# create new links symlink libc.so
run ln -sf libc.so "ld-musl-$MUSL_ARCH.so.1"


# Step 6: build libgcc-shared
# ------------------------------------------------------------------------------

# cd to the gcc build dir
printstatus "Configuring libgcc-$pkg_gcc_version-shared"
run cd "$bdir/src/build-gcc"

# configure libgcc-shared
run make \
    $MAKEOPTS \
    -C $TARGET/libgcc distclean

# compile libgcc-shared
printstatus "Compiling libgcc-$pkg_gcc_version-shared"
run make \
    $MAKEOPTS \
    enable_shared=yes \
    all-target-libgcc

# install libgcc-shared
printstatus "Installing libgcc-$pkg_gcc_version-shared"
run make \
    $MAKEOPTS \
    DESTDIR="$bdir" \
    install-strip-target-libgcc

# cd to the library dir
cd "$bdir/lib"

# create links to libgcc objects in /lib (the linker/loader might not find them in the gcc subpath)
for i in gcc/$TARGET/$pkg_gcc_version/*.o gcc/$TARGET/$pkg_gcc_version/*.so gcc/$TARGET/$pkg_gcc_version/*.a; do
    [ -r "$i" ] && [ ! -r "${i##gcc/$TARGET/$pkg_gcc_version/}" ] && run ln -sf $i ${i##gcc/$TARGET/$pkg_gcc_version/}
done


# Step 7: build libstdc++
# ------------------------------------------------------------------------------

# cd back to the gcc build dir
run cd "$bdir/src/build-gcc"
printstatus "Configuring libstdc++-v3"

# configure libstdc++
run make \
    $MAKEOPTS \
    configure-target-libstdc++-v3

# compile libstdc++
printstatus "Compiling libstdc++-v3"
run make \
    $MAKEOPTS \
    all-target-libstdc++-v3

# install libstdc++v3
printstatus "Installing libstdc++-v3"
run make \
    $MAKEOPTS \
    DESTDIR="$bdir" \
    install-strip-target-libstdc++-v3

# cd to the library dir
cd "$bdir/lib"

# create links to libgcc objects in /lib (the linker/loader might not find them in the gcc subpath)
for i in gcc/$TARGET/$pkg_gcc_version/*.o gcc/$TARGET/$pkg_gcc_version/*.so gcc/$TARGET/$pkg_gcc_version/*.a; do
    [ -r "$i" ] && [ ! -r "${i##gcc/$TARGET/$pkg_gcc_version/}" ] && run ln -sf $i ${i##gcc/$TARGET/$pkg_gcc_version/}
done


# we're finished!
# ------------------------------------------------------------------------------

# cd to bdir
run cd "$bdir"

# give the user a shell if applicable
[ -n "$spawn_shell" ] && HISTFILE="$CCBROOT/shell_history.txt" eval "$spawn_shell"

# move to the binary dir
run cd "$bdir/bin"

# strip the target triplet from binary names
for i in $TARGET-*; do
    [ -r "${i##$TARGET-}" ] || run ln -sf $i ${i##$TARGET-}
done

# remove junk
run rm -rf "$bdir/_tmp"

# delete all sources if desired
[ "$build_post_cleanup" = "y" ] && run rm -rf "$bdir/src"

# get the end timestamp
[ "$timestamping" = "y" ] && {
    get_timestamp end
}

printf -- "Successfully built for $CPU_NAME/musl (${bdir##$CCBROOT/})${end_time:+ in $(fmt_timestamp $(diff_timestamp "$start_time" "$end_time"))} ${download_time:+($(fmt_timestamp "$download_time") spent downloading)}\n" >&2
