#!/bin/sh

# vi: ts=4 sw=4 sts=4 et

# Copyright (C) 2024 Andrew Blue <andy@antareslinux.org>
# Distributed under the terms of the ISC license.
# See the LICENSE file for more information.

# don't mind the useless comments above self-explanatory lines; having them
# there satisfies my OCD and it looks weird without them to me for some
# reason...

# this should be implied on all invocations
alias printf="printf --"

# a few shells don't have this; in our case, variables just need to be emptied
# rather than undefined so this backup fills that role
command -v unset >/dev/null 2>&1 || eval "unset() { for _i in \"\$@\"; do eval \"\$_i=\\\"\\\"\"; done; }"

# try to cd to the cwd of the script
# only works if $0 is a path to build.sh, not a basename
test -z "${0%%/*}" && cd /
IFS="/"
for i in $0; do
    test -d "$i" && cd "$i"
done
IFS="$(printf ' \n\t')"

# save script cwd
export CCBROOT="$PWD"

# make sure we're in the right place
test -z "$CCBROOT" && printf "${0##*/}: error: CCBROOT can't be set\n" >&2 && exit 1
test ! -r "$CCBROOT/${0##*/}" && printf "${0##*/}: error: CCBROOT set incorrectly\n" >&2 && exit 1
test ! -r "$CCBROOT/util.sh" && printf "${0##*/}: error: util.sh: No such file or directory\n" >&2 && exit 1

# load utility functions (these are separated so build.sh stays clean and simple)
. "$CCBROOT/util.sh"

# define packages
def_pkg mpc "1.3.1" "http://ftpmirror.gnu.org/mpc/mpc-\${version}.tar.gz"
def_pkg musl "1.2.5" "http://musl.libc.org/releases/musl-\${version}.tar.gz"
def_pkg mpfr "4.2.1" "http://ftpmirror.gnu.org/mpfr/mpfr-\${version}.tar.xz"
def_pkg isl "0.26" "http://libisl.sourceforge.io/isl-\${version}.tar.xz"
def_pkg gmp "6.3.0" "http://ftpmirror.gnu.org/gmp/gmp-\${version}.tar.xz"
def_pkg binutils "2.42" "http://ftpmirror.gnu.org/binutils/binutils-\${version}.tar.xz"
def_pkg gcc "14.1.0" "http://ftpmirror.gnu.org/gcc/gcc-\${version}/gcc-\${version}.tar.xz"

# ------------------------------------------------------------------------------

# parse command-line arguments
while test "$#" -gt 0; do
    case "$1" in
        --clean)            rm -rf "$CCBROOT/out" "$CCBROOT/cache" "$CCBROOT/ccbuild.log"; exit $? ;;
        -C|--cleanup)       clean_src="y"; shift ;;
        +C|--no-cleanup)    clean_src="n"; shift ;;
        -c|--cmdline)       log_commands="y"; shift ;;
        +c|--no-cmdline)    log_commands="n"; shift ;;
        --enable-fortran)   use_fortran="y" use_quadmath="y"; shift ;;
        --disable-fortran)  use_fortran="n"; test "$use_quadmath_specified" = "y" || use_quadmath="n"; shift ;;
        --enable-quadmath)  use_quadmath="y"; use_quadmath_specified="y"; shift ;;
        --enable-*)         eval "use_${1##--enable-}=y"; shift ;;
        --disable-*)        eval "use_${1##--disable-}=n"; shift ;;
        -h|--help)          print_help; exit ;;
        -j|--jobs)          test "$2" -le 1024 2>/dev/null            && jobs="$2"; shift 2 ;;
        -j*)                test "${1##-j}" -le 1024 2>/dev/null      && jobs="${1##-j}"; shift ;;
        --jobs=*)           test "${1##--jobs=}" -le 1024 2>/dev/null && jobs="${1##--jobs=}"; shift ;;
        -l|--log)           log_file="$CCBROOT/ccbuild.log"; :>"$log_file"; shift ;;
        -l*)                log_file="${1##-l}";             :>"$log_file"; shift ;;
        --log=*)            log_file="${1##--log=}";         :>"$log_file"; shift ;;
        +l|--no-log)        unset log_file; shift ;;
        -n|--name)          bname="$2";            shift 2 ;;
        -n*)                bname="${1##-n}";      shift ;;
        --name=*)           bname="${1##--name=}"; shift ;;
        -q|--quieter)       verbosity="quieter"; shift ;;
        -s|--silent)        verbosity="silent";  shift ;;
        --shell)            spawn_shell="y"; shift ;;
        --time-fmt)         str_match "$2" 'l' 's' && time_fmt="$2"; shift 2 ;;
        --time-fmt=*)       str_match "${1##--ts-unit-fmt=}" 'l' 's' && time_fmt="${1##--ts-unit-fmt=}"; shift ;;
        --targets)          for i in "$CCBROOT"/arch/*.conf; do test -L "$i" && continue; i="${i%%.conf}"; printf "${i##*/} "; done; printf "\n"; exit ;;
        -v|--verbose)       verbosity="normal"; shift ;;
        *)                  test -z "$target" && target="${1%%/}"; shift ;;
    esac
done

# defaults for options
: "${clean_src:=y}"
: "${log_commands:=n}"
: "${use_atomic:=n}"
: "${use_cxx:=y}"
: "${use_ffi:=n}"
: "${use_fortran:=n}"
: "${use_openmp:=n}"
: "${use_itm:=n}"
: "${use_lto:=n}"
: "${use_phobos:=n}"
: "${use_quadmath:=n}"
: "${use_ssp:=n}"
: "${use_vtv:=n}"
: "${jobs:=1}"
: "${spawn_shell:=n}"
: "${time_fmt:=l}"
: "${verbosity:=normal}"
#: "${log_file:=$CCBROOT/ccbuild.log}"

# export these variables
set -a

# try to load the architecture build flags
test ! -r "$CCBROOT/arch/$target.conf" -a -n "$target" && error "Invalid option or target $target"
test ! -r "$CCBROOT/arch/$target.conf" && error "No target specified. Run \`$0 --help\` for more information."
. "$CCBROOT/arch/$target.conf"

# set the build directory for a new toolchain
bdir="$CCBROOT/out/${bname:=ccb-$CPU_NAME}"
test -d "$CCBROOT/out/$bname" && {
    i="2"
    while test -d "$CCBROOT/out/$bname.$i"; do
        i="$((i+1))"
    done
    bdir="$CCBROOT/out/$bname.$i"
}

# environment variables
CFLAGS="-pipe -Os -s -g0 -ffunction-sections -fdata-sections -fmerge-all-constants"
CXXFLAGS="-pipe -Os -s -g0 -ffunction-sections -fdata-sections -fmerge-all-constants"
LDFLAGS="-s -Wl,--gc-sections,-s,-z,now,--hash-style=sysv,--build-id=none,--sort-section,alignment"
JOBS="${jobs:-1}"
PATH="$CCBROOT/misc/bin:$bdir/bin:$PATH"
HISTFILE="$CCBROOT/shell_history.txt"
PKG_CONFIG_PATH="$bdir/lib/pkgconfig"
PKG_CONFIG_LIBDIR="$bdir/lib/pkgconfig"
PKG_CONFIG_SYSROOT_DIR="$bdir"
PKG_CONFIG_SYSTEM_INCLUDE_PATH="$bdir/include"
PKG_CONFIG_SYSTEM_LIBRARY_PATH="$bdir/lib"

# gcc langs
GCCLANGS="c"
test "$use_cxx" = "y" && GCCLANGS="${GCCLANGS:+$GCCLANGS,}c++"
test "$use_fortran" = "y" && GCCLANGS="${GCCLANGS:+$GCCLANGS,}fortran"
test "$use_lto" = "y" && GCCLANGS="${GCCLANGS:+$GCCLANGS,}lto"

# make/cmake command lines
MAKEOPTS="INFO_DEPS= MAKEINFO=true ac_cv_prog_lex_root=lex.yy -j$JOBS"

# don't export any more variables implicitly
set +a


# Step 0: set up the environment
# ------------------------------------------------------------------------------

# print the starting status message
test "$verbosity" != "silent" && printf "Starting build for $CPU_NAME/musl (%s) with $JOBS thread$(test "$JOBS" != "1" && printf "s")\n" "${bdir##$CCBROOT/}" >&2

# check if we have thee commands needed for timestamping
command -v date >/dev/null 2>&1 && command -v awk >/dev/null 2>&1 && timestamping="y" && start_time="$(get_timestamp)"

# create a dir to store downloaded files
test ! -d "$CCBROOT/cache" && run mkdir -p "$CCBROOT/cache"

# cd to the cache dir
run cd "$CCBROOT/cache"

# get source tarballs
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
    bin \
    lib \
    lib32 \
    include \
    src \
    _tmp \
    "$TARGET/bin"

# symlink usr to its parent (compatibility)
run ln -sf . usr

# create symlinks
run cd "$bdir/$TARGET"
run ln -sf ../lib lib
run ln -sf ../lib32 lib32
run ln -sf ../include include

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
    --libexecdir="/lib" \
    --datarootdir="/_tmp" \
    --target="$TARGET" \
    --with-pkgversion="$bname" \
    --enable-default-hash-style="sysv" \
    --enable-default-pie \
    --enable-static-pie \
    --enable-relro \
    --disable-bootstrap \
    "$(if test "$use_lto" = "y"; then printf "--enable-lto"; else printf "--disable-lto"; fi)" \
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
run cd "$bdir/bin"

# empty path
for i in $TARGET-*; do
    test -r "../$TARGET/bin/${i##$TARGET-}" && run rm -f "$i" && continue
    run mv -f "$i" "../$TARGET/bin/${i##$TARGET-}"
done

# link ld.bfd to ld
run cd "$bdir/$TARGET/bin"
run ln -sf ld.bfd ld

# move back to where binaries can be accessed by PATH
run cd "$bdir/bin"

# link utils to path
for i in ../$TARGET/bin/*; do
    test ! -r "$TARGET-${i##*/}" && run ln -sf "$i" "$TARGET-${i##*/}"
done


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
    --libexecdir="/lib" \
    --datarootdir="/_tmp" \
    --target="$TARGET" \
    --with-pkgversion="$bname" \
    --enable-languages="$GCCLANGS" \
    --enable-default-hash-style="sysv" \
    --enable-default-pie \
    --enable-static-pie \
    --enable-relro \
    --enable-libstdcxx=time=rt \
    --enable-initfini-array \
    --disable-bootstrap \
    "$(if test "$use_lto" = "y"; then printf "--enable-lto"; else printf "--disable-lto"; fi)" \
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
run cd "$bdir/bin"
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

# symlink everything else
run cd "$bdir/$TARGET/bin"
for i in ../../bin/*; do
    test ! -r "${i##*/$TARGET-}" && run ln -sf "$i" "${i##*/$TARGET-}"
done


# Step 4: build libgcc-static
# ------------------------------------------------------------------------------

# move back to the gcc build dir
printstatus "Compiling libgcc-static"
run cd "$bdir/src/build-gcc"

# compile gcc
run make \
    $MAKEOPTS \
    enable_shared=no \
    all-target-libgcc

# install gcc
printstatus "Installing libgcc-static"
run make \
    $MAKEOPTS \
    DESTDIR="$bdir" \
    install-strip-target-libgcc

# cd to the library dir
run cd "$bdir/lib"

# create links to libgcc objects in /lib (the linker/loader might not find them in the gcc subpath)
for i in gcc/$TARGET/$pkg_gcc_version/*.o gcc/$TARGET/$pkg_gcc_version/*.so gcc/$TARGET/$pkg_gcc_version/*.a; do
    test -r "$i" -a ! -r "${i##gcc/$TARGET/$pkg_gcc_version/}" && run ln -sf $i ${i##gcc/$TARGET/$pkg_gcc_version/}
done


# Step 5: build musl libc
# ------------------------------------------------------------------------------

# move to the musl build dir
printstatus "Configuring musl-$pkg_musl_version"
run cd "$bdir/src/$pkg_musl_dirname"

# configure musl
ARCH="$MUSL_ARCH" \
CC="$TARGET-gcc" \
LIBCC="$bdir/lib/libgcc.a" \
CROSS_COMPILE="$TARGET-" \
run ./configure \
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
run cd "$bdir/lib"

# link names of the dynamic loader to libc.so
for i in ld-*.so ld-*.so.*; do
    test -r "$i" && run ln -sf libc.so "$i"
done


# Step 6: build libgcc-shared
# ------------------------------------------------------------------------------

# cd to the gcc build dir
printstatus "Configuring libgcc-shared"
run cd "$bdir/src/build-gcc"

# configure libgcc-shared
run make \
    $MAKEOPTS \
    -C $TARGET/libgcc distclean

# compile libgcc-shared
printstatus "Compiling libgcc-shared"
run make \
    $MAKEOPTS \
    enable_shared=yes \
    all-target-libgcc

# install libgcc-shared
printstatus "Installing libgcc-shared"
run make \
    $MAKEOPTS \
    DESTDIR="$bdir" \
    install-strip-target-libgcc

# cd to the library dir
run cd "$bdir/lib"

# create links to libgcc objects in /lib (the linker/loader might not find them in the gcc subpath)
for i in gcc/$TARGET/$pkg_gcc_version/*.o gcc/$TARGET/$pkg_gcc_version/*.so gcc/$TARGET/$pkg_gcc_version/*.a; do
    test -r "$i" -a ! -r "${i##gcc/$TARGET/$pkg_gcc_version/}" && run ln -sf $i ${i##gcc/$TARGET/$pkg_gcc_version/}
done


# Step 7: build libstdc++
# ------------------------------------------------------------------------------

# don't build if not enabled
test "$use_cxx" = "y" && {
    # cd back to the gcc build dir
    run cd "$bdir/src/build-gcc"

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
        test -r "$i" -a ! -r "${i##gcc/$TARGET/$pkg_gcc_version/}" && run ln -sf $i ${i##gcc/$TARGET/$pkg_gcc_version/}
    done
}


# Step 8: build libquadmath
# ------------------------------------------------------------------------------

# don't build if not enabled
test "$use_quadmath" = "y" && {
    # cd back to the gcc build dir
    run cd "$bdir/src/build-gcc"

    # compile libquadmath
    printstatus "Compiling libquadmath"
    run make \
        $MAKEOPTS \
        all-target-libquadmath

    # install libquadmath
    printstatus "Installing libquadmath"
    run make \
        $MAKEOPTS \
        DESTDIR="$bdir" \
        install-target-libquadmath

    # cd to the library dir
    cd "$bdir/lib"

    # create links to libgcc objects in /lib (the linker/loader might not find them in the gcc subpath)
    for i in gcc/$TARGET/$pkg_gcc_version/*.o gcc/$TARGET/$pkg_gcc_version/*.so gcc/$TARGET/$pkg_gcc_version/*.a gcc/$TARGET/$pkg_gcc_version/*.la; do
        test -r "$i" -a ! -r "${i##gcc/$TARGET/$pkg_gcc_version/}" && run ln -sf $i ${i##gcc/$TARGET/$pkg_gcc_version/}
    done
}


# Step 9: build libatomic
# ------------------------------------------------------------------------------

# don't build if not enabled
test "$use_atomic" = "y" && {
    # cd back to the gcc build dir
    run cd "$bdir/src/build-gcc"

    # compile libatomic
    printstatus "Compiling libatomic"
    run make \
        $MAKEOPTS \
        all-target-libatomic

    # install libatomic
    printstatus "Installing libatomic"
    run make \
        $MAKEOPTS \
        DESTDIR="$bdir" \
        install-strip-target-libatomic
}


# Step 10: build libffi
# ------------------------------------------------------------------------------

# don't build if not enabled
test "$use_ffi" = "y" && {
    # compile libffi
    printstatus "Compiling libffi"
    run make \
        $MAKEOPTS \
        all-target-libffi

    # install libffi
    printstatus "Installing libffi"
    run make \
        $MAKEOPTS \
        DESTDIR="$bdir" \
        install-strip-target-libffi
}


# Step 11: build libgfortran
# ------------------------------------------------------------------------------

# don't build if not enabled
test "$use_fortran" = "y" && {
    # compile libgfortran
    printstatus "Compiling libgfortran"
    run make \
        $MAKEOPTS \
        all-target-libgfortran

    # install libgfortran
    printstatus "Installing libgfortran"
    run make \
        $MAKEOPTS \
        DESTDIR="$bdir" \
        install-strip-target-libgfortran

    # cd to the library dir
    cd "$bdir/lib"

    # create links to libgcc objects in /lib (the linker/loader might not find them in the gcc subpath)
    for i in gcc/$TARGET/$pkg_gcc_version/*.o gcc/$TARGET/$pkg_gcc_version/*.so gcc/$TARGET/$pkg_gcc_version/*.a gcc/$TARGET/$pkg_gcc_version/*.la; do
        test -r "$i" -a ! -r "${i##gcc/$TARGET/$pkg_gcc_version/}" && run ln -sf $i ${i##gcc/$TARGET/$pkg_gcc_version/}
    done
}


# Step 12: build libgomp
# ------------------------------------------------------------------------------

# don't build if not enabled
test "$use_openmp" = "y" && {
    # cd back to the gcc build dir
    run cd "$bdir/src/build-gcc"

    # compile libgomp
    printstatus "Compiling libgomp"
    run make \
        $MAKEOPTS \
        all-target-libgomp

    # install libgomp
    printstatus "Installing libgomp"
    run make \
        $MAKEOPTS \
        DESTDIR="$bdir" \
        install-strip-target-libgomp
}


# Step 13: build libitm
# ------------------------------------------------------------------------------

# don't build if not enabled
# broken for now
#test "$use_itm" = "y" && {
#    # configure libitm
#    printstatus "Configuring libitm"
#
#    run make \
#        $MAKEOPTS \
#        configure-target-libitm
#
#    # compile libitm
#    printstatus "Compiling libitm"
#    run make \
#        $MAKEOPTS \
#        all-target-libitm
#
#    # install libitm
#    printstatus "Installing libitm"
#    run make \
#        $MAKEOPTS \
#        DESTDIR="$bdir" \
#        install-strip-target-libitm
#}


# Step 14: build libphobos
# ------------------------------------------------------------------------------

# don't build if not enabled
test "$use_phobos" = "y" && {
    # compile libphobos
    printstatus "Compiling libphobos"
    run make \
        $MAKEOPTS \
        all-target-libphobos

    # install libphobos
    printstatus "Installing libphobos"
    run make \
        $MAKEOPTS \
        DESTDIR="$bdir" \
        install-strip-target-libphobos
}


# Step 15: build libssp
# ------------------------------------------------------------------------------

# don't build if not enabled
test "$use_ssp" = "y" && {
    # compile libssp
    printstatus "Compiling libssp"
    run make \
        $MAKEOPTS \
        all-target-libssp

    # install libssp
    printstatus "Installing libssp"
    run make \
        $MAKEOPTS \
        DESTDIR="$bdir" \
        install-strip-target-libssp
}


# Step 16: build libvtv
# ------------------------------------------------------------------------------

# don't build if not enabled
test "$use_vtv" = "y" && {
    # compile libvtv
    printstatus "Compiling libvtv"
    run make \
        $MAKEOPTS \
        all-target-libvtv

    # install libvtv
    printstatus "Installing libvtv"
    run make \
        $MAKEOPTS \
        DESTDIR="$bdir" \
        install-strip-target-libvtv
}


# we're finished!
# ------------------------------------------------------------------------------

# we might want to open a shell here
test "$spawn_shell" = "y" && {
    run cd "$bdir"
    printf "You are entering a shell spawned by ccbuild, preserving the build environment\nand its variables. When you are done, use the \`exit\` command or ^D to exit.\n"
    eval "${SHELL:-/bin/sh}"
}

# delete useless directories
test -d "$bdir/_tmp" && run rm -rf "$bdir/_tmp"
test -d "$bdir/src" -a "$clean_src" = "y" && run rm -rf "$bdir/src"

# get the end timestamp
test "$timestamping" = "y" && end_time="$(get_timestamp)"

# print status message
printf "Successfully built for $CPU_NAME/musl (${bdir##$CCBROOT/})%s%s\n" \
    "$(test -n "$end_time" && printf " in $(fmt_timestamp $(diff_timestamp "$start_time" "$end_time"))")" \
    "$(test -n "$download_time" && printf " ($(fmt_timestamp "$download_time") spent downloading)")" >&2
