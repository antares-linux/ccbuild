#!/bin/sh

# Copyright (C) 2024 Andrew Blue <andy@antareslinux.org>
#
# Distributed under the terms of the MIT license.
# See the LICENSE file for more information.

# print the help message
print_help() {
    printf -- "Usage: $0 [OPTIONS]... [TARGET]

Options:
      --allow-root          allow the script to be run with root privileges
      --no-checkhash        don't verify hashes of downloaded packages
      --clean               remove all cached tarballs, builds, and logs
  -C, --cleanup             clean up unpacked sources for the current build
      --no-cleanup          don't clean up unpacked sources for the current build (default)
  -c, --cmdline             print relevant commands as they are processed
      --no-cmdline          don't print relevant commands as they are processed (default)
      --enable-cxx          build c++ support (default)
      --disable-cxx         don't build c++ support
      --enable-fortran      build fortran support
      --disable-fortran     don't build fortran support (default)
      --enable-quadmath     build libquadmath (default if fortran is enabled)
      --disable-quadmath    don't build quadmath (default)
  -h, --help                print this message
  -j, --jobs=JOBS           concurrent job/task count
  -l, --log                 log build information to ccbuild.log
      --no-log              don't log build information to ccbuild.log (default)
  -n, --name=NAME           name of the build (default: ccb-TARGET)
  -p, --pkgconfig           fetch and build pkgconf configured for the toolchain (default)
      --no-pkgconfig        don't fetch and build pkgconf
  -q, --quieter             reduce output to status messages if printing to a terminal
  -s, --silent              completely disable output if printing to a terminal
      --shell               spawn a subshell when the build finishes
      --targets             print a list of available targets and exit (default)
  -t, --timestamping        enable timestamping
      --no-timestamping     don't enable timestamping (default)
  -v, --verbose             enable all terminal output (default)\n"
}

# ensure a provided command is installed
require_command() {
    # if it's a script, we're good
    [ -x "$1" ] && return 0

    # check if it's a builtin/alias/$PATH binary
    command -v "$1" >/dev/null 2>&1 || {
        printf -- "${0##*/}: $1: command not found\n" >&2
        exit 3
    }
}

# print status messages
printstatus() {
    [ "$printcmdline" != "y" ] && {
        [ "$verbosity" = "normal" ] && [ -n "$buildlog" ] && printf -- "%s\n" "$1" >&2
        [ "$verbosity" = "quieter" ] && printf -- "%s\n" "$1" >&2
    }
}

# print a list of the non-symbolic files in ./arch/ (kinda useful)
list_targets() {
    for i in "$CCBROOT"/arch/*.conf; do
        [ -L "$i" ] || {
            i="${i%%.conf}"
            arches="${arches:+$arches }${i##*/}"
        }
    done
    printf -- "$arches\n"
}

# read package vars
read_pkg() {
    # initialize these
    unset name version link dirname checksum patchpaths

    # read package info
    [ -n "$1" ] && {
        eval "[ -n \"\$pkg_${1}_name\" ]" && {
            eval "name=\"\$pkg_${1}_name\""
            eval "version=\"\$pkg_${1}_version\""
            eval "link=\"\$pkg_${1}_link\""
            eval "checksum=\"\$pkg_${1}_checksum\""
            eval "dirname=\"\$pkg_${1}_dirname\""
            eval "patchpaths=\"\$pkg_${1}_patchpaths\""
        } || {
            printf -- "${0##*/}: error: read_pkg: Package $1 has not been defined\n" >&2
            exit 1
        }
    } || {
        printf -- "${0##*/}: error: read_pkg: No package name specified\n" >&2
        exit 1
    }
}

# set variabless containing info about a package
# name, version, link, dirname, checksum
def_pkg() {
    # require these commands
    require_command sed

    # initialize these
    unset name version link checksum dirname patchpaths

    # set the package name
    [ -n "$1" ] && {
        name="$1"
        eval "pkg_${name}_name=\"$name\""
    } || {
        printf -- "${0##*/}: error: def_pkg: No package name specified\n" >&2
        exit 1
    }

    # set the version
    [ -n "$2" ] && {
        version="$2"
        eval "pkg_${name}_version=\"$version\""
    }

    # set the package link
    [ -n "$3" ] && {
        link="$(printf -- "$3" | sed -e "s/#:ver:#/$version/g")"
        eval "pkg_${name}_link=\"$link\""
        eval "pkg_${name}_archive=\"${link##*/}\""
    } || {
        printf -- "${0##*/}: error: def_pkg: No package link specified\n" >&2
        exit 1
    }

    # set the package checksum
    [ -n "$4" ] && {
        checksum="$4"
        eval "pkg_${name}_checksum=\"$checksum\""
    }

    # set the package dirname, if the default should be overridden
    [ -n "$5" ] && {
        dirname="$(printf -- "$5" | sed -e "s/#:ver:#/$version/g")"
    } || {
        dirname="$name-$version"
    }
    eval "pkg_${name}_dirname=\"$dirname\""

    # set the directories to check for patches
    for i in "$CCBROOT/patches/${name:-placeholder_name}" "$CCBROOT/patches/${name:-placeholder_name}/$version" "$CCBROOT/patches/${name:-placeholder_name}-$version"; do
        [ -d "$i" ] && patchpaths="${patchpaths:+$patchpaths }$i"
    done
    eval "pkg_${name}_patchpaths=\"$patchpaths\""
}

# download a package
get_pkg() {
    # initialize these
    unset gcmd dl_start_time dl_start_sec dl_start_ms dl_end_time dl_end_sec dl_end_ms dl_time

    # read package info
    read_pkg "$1"

    # exit if the package is downloaded
    [ -r "${link##*/}" ] && return 0

    # decide which download command to use
    for i in lynx w3m rsync wget curl aria2c; do
        command -v "$i" >/dev/null 2>&1 && gcmd="$i"
    done

    # print a status message
    eval "printstatus \"Downloading \${pkg_${1}_link##*/}\""

    # get the time before a download starts
    [ "$timestamping" = "y" ] && {
        get_timestamp dl_start
    }

    # download the tarball with lynx
    #[ "$gcmd" = "lynx" ] && run lynx

    # download the tarball with w3m
    #[ "$gcmd" = "w3m" ] && run w3m

    # download the tarball with rsync
    #[ "$gcmd" = "rsync" ] && run rsync

    # download the tarball with aria2c
    [ "$gcmd" = "aria2c" ] && run aria2c -s "$JOBS" -j "$JOBS" -o "${link##*/}" "$link"

    # download the tarball with curl
    [ "$gcmd" = "curl" ] && run curl -fL# -o "${link##*/}" "$link"

    # download the tarball with wget
    [ "$gcmd" = "wget" ] && run wget -O "${link##*/}" "$link"

    # get the time before a download starts
    [ "$timestamping" = "y" ] && {
        # get the time at the end of the download and the time it took
        get_timestamp dl_end
        dl_time="$(diff_timestamp "$dl_start_time" "$dl_end_time")"

        # add to the total amount of time spent downloading
        download_time="$(printf -- "${download_time:+$download_time + }$dl_time\n" | bc -ql)"
        [ -z "$(printf -- "$download_time" | awk -F. '{print $1}')" ] && download_time="0$download_time"
    }

    # verify the hash of the tarball
    [ "$verify_hash" = "y" ] && {
        run check_hash "${link##*/}" "$checksum"
    }

    # prevent the hash checking function from being run again on this package
    eval "pkg_${name}_verified=y"
}

# prepare and patch a package for building
prep_pkg() {
    # read package info
    read_pkg "$1"

    # check if the package is downloaded
    [ -r "$CCBROOT/cache/${link##*/}" ] || {
        printf -- "${0##*/}: error: prep_pkg: Package not downloaded\n" >&2
        exit 1
    }

    # decide if we need to re-check the tarball's hash
    eval "[ \"\$pkg_${name}_verified\" = y ]" || {
        run check_hash "$CCBROOT/cache/${link##*/}" "$checksum"
        eval "pkg_${name}_verified=y"
    }

    # print a status message
    printstatus "Opening ${link##*/}"

    # unpack the tarball
    run tar -xpf "$CCBROOT/cache/${link##*/}"

    # check if the dir exists
    run test -d "$dirname"

    # cd to the dir
    cd "$dirname"

    # check if there are patches for this package
    [ -n "$patchpaths" ] && {
        printstatus "Patching $name-$version"
        for i in $patchpaths; do
            [ -d "$i" ] && {
                for j in $i/*.patch $i/*.diff; do
                    [ -r "$j" ] && run patch -p0 -i "$j"
                done
            }
            [ -d "$i/$CPU_NAME" ] && {
                for k in $i/*.patch $i/*.diff; do
                    [ -r "$k" ] && run patch -p0 -i "$k"
                done
            }
        done
    }

    # cd to the parent directory
    cd ..
}

# compute md5/sha1/sha224/sha256/sha384/sha512 hashes and check if they match the hash provided
check_hash() {
    # require awk
    require_command awk

    # check if the specified file exists
    [ -r "$1" ] || {
        printf -- "${0##*/}: error: $1: No such file or directory\n" >&2
        exit 1
    }

    # print a status message
    printstatus "Hashing ${1##*/}"

    # guess the type of hash based on its length
    case "$(printf -- "$2" | wc -c)" in
           0) return 0 ;;

          32) test "$(md5sum "$1" | awk '{print $1}')" = "$2"; ec="$?"
              [ "$ec" -gt 0 ] && printf -- "check_hash: error: $1: Hash mismatch or compute failure\n"; return "$ec" ;;

          40) test "$(sha1sum "$1" | awk '{print $1}')" = "$2"; ec="$?"
              [ "$ec" -gt 0 ] && printf -- "check_hash: error: $1: Hash mismatch or compute failure\n"; return "$ec" ;;

          56) test "$(sha224sum "$1" | awk '{print $1}')" = "$2"; ec="$?"
              [ "$ec" -gt 0 ] && printf -- "check_hash: error: $1: Hash mismatch or compute failure\n"; return "$ec" ;;

          64) test "$(sha256sum "$1" | awk '{print $1}')" = "$2"; ec="$?"
              [ "$ec" -gt 0 ] && printf -- "check_hash: error: $1: Hash mismatch or compute failure\n"; return "$ec" ;;

          96) test "$(sha384sum "$1" | awk '{print $1}')" = "$2"; ec="$?"
              [ "$ec" -gt 0 ] && printf -- "check_hash: error: $1: Hash mismatch or compute failure\n"; return "$ec" ;;

         128) test "$(sha512sum "$1" | awk '{print $1}')" = "$2"; ec="$?"
              [ "$ec" -gt 0 ] && printf -- "check_hash: error: $1: Hash mismatch or compute failure\n"; return "$ec" ;;

           *) return 1;
     esac
}

# get a timestamp
get_timestamp() {
    # initialize these
    unset time

    # store time
    [ "$has_ns" = "y" ] && {
        time="$(date +%s.%N)"
        eval "${1:+$1_}sec=\"$(printf -- "$time" | awk -F. '{print $1}')\""
        eval "${1:+$1_}ms=\"$(printf -- "$time" | awk -F. '{print $2}' | head -c3)\""
        eval "${1:+$1_}time=\"$time\""
    } || {
        time="$(date +%s)"
        eval "${1:+$1_}time=\"$time\""
    }
}

# get the difference between two timestamps
diff_timestamp() {
    # initialize these
    unset ts_diff ts_diff_sec ts_diff_ms

    # required cmds
    require_command bc awk head

    # pipe args into bc
    ts_diff="$(printf -- "$2 - $1\n" | bc -ql)"
    ts_diff="${ts_diff#-}"
    #ts_diff="$(printf -- "$ts_diff + 100000000\n" | bc -ql)"

    # get seconds
    ts_diff_sec="$(printf -- "$ts_diff" | awk -F. '{print $1}')"
    ts_diff_sec="${ts_diff_sec:-0}"

    # get ms if possible
    ts_diff_ms="$(printf -- "${ts_diff##$ts_diff_sec}" | awk -F. '{print $2}' | head -c3)"

    # print the time difference
    printf -- "$ts_diff_sec${ts_diff_ms:+.$ts_diff_ms}"
}

# format a timestamp string
fmt_timestamp() {
    # initialize these
    unset time seconds miliseconds years months weeks days hours minutes

    # store time
    time="${1:-0}"
    seconds="$(printf -- "$time" | awk -F. '{print $1}')"
    miliseconds="$(printf -- "${time##$seconds}" | awk -F. '{print $2}' | head -c3)"

    # format suffixes
    [ "$unitsize" = "s" ] && {
        yearsuffix="y"
        monthsuffix="m"
        weeksuffix="w"
        daysuffix="d"
        hoursuffix="h"
        minutesuffix="m"
        secondsuffix="s"
    } || {
        yearsuffix=" years"
        monthsuffix=" months"
        weeksuffix=" weeks"
        daysuffix=" days"
        hoursuffix=" hours"
        minutesuffix=" minutes"
        secondsuffix=" seconds"
    }

    # count the amount of years (lol)
    while [ "$seconds" -ge 31557600 ]; do
        seconds="$((seconds-31557600))"
        years="$((years+1))"
    done
    [ "$years" -ne 1 >&- 2>&- ] || yearsuffix="${yearsuffix%s}"

    # count the amount of months
    while [ "$seconds" -ge 2628000 ]; do
        seconds="$((seconds-2628000))"
        months="$((months+1))"
    done
    [ "$months" -ne 1 >&- 2>&- ] || monthsuffix="${monthsuffix%s}"

    # count the amount of weeks
    while [ "$seconds" -ge 604800 ]; do
        seconds="$((seconds-604800))"
        weeks="$((weeks+1))"
    done
    [ "$weeks" -ne 1 >&- 2>&- ] || weeksuffix="${weeksuffix%s}"

    # count the amount of days
    while [ "$seconds" -ge 86400 ]; do
        seconds="$((seconds-86400))"
        days="$((days+1))"
    done
    [ "$days" -ne 1 >&- 2>&- ] || daysuffix="${daysuffix%s}"

    # count the amount of hours
    while [ "$seconds" -ge 3600 ]; do
        seconds="$((seconds-3600))"
        hours="$((hours+1))"
    done
    [ "$hours" -ne 1 >&- 2>&- ] || hoursuffix="${hoursuffix%s}"

    # count the amount of minutes
    while [ "$seconds" -ge 60 ]; do
        seconds="$((seconds-60))"
        minutes="$((minutes+1))"
    done
    [ "$minutes" -ne 1 >&- 2>&- ] || minutesuffix="${minutesuffix%s}"

    # singular second prefix if miliseconds aren't counted
    [ "$seconds" -ne 1 >&- 2>&- ] || [ -n "$miliseconds" ] || [ "$secondprefix" = "s" ] || secondsuffix="${secondsuffix%s}"

    # if less than 1 second, use a short prefix
    [ "$seconds" -lt 1 >&- 2>&- ] && {
        secondsuffix="s"
    }

    # print the timestamp difference
    printf -- "${years:+$years$yearsuffix, }${months:+$months$monthsuffix, }${weeks:+$weeks$weeksuffix, }${days:+$days$daysuffix, }${hours:+$hours$hoursuffix, }${minutes:+$minutes$minutesuffix, }$seconds${miliseconds:+.$miliseconds}$secondsuffix\n"
}


# wrapper function for running important commands: manages output content/redirection and argument parsing
# slows down the script marginally, but I think it's useful enough to be worth it
run() {
    # initialize these
    unset cmd argc argv args suf printcd ec

    # store the command name
    require_command "$1" && cmd="$1" && shift

    # decide what flags to append to commands
    case "${cmd##*/}" in
        mkdir|cp|ln|rm|curl|mv|tar) suf="-v" ;;
        cd|pushd|popd) printcd="y" ;;
    esac

    # commands print what they normally do
    [ "$verbosity" = "quieter" ] && [ -z "$buildlog" ] && {
        suf=""
        case "${cmd##*/}" in
            make|configure|wget|aria2c|patch) suf=">/dev/null" ;;
        esac
    }

    # output handling
    [ -n "$buildlog" ] && {
        suf="${suf:+$suf }>>'$buildlog' 2>&1"
    } || {
        suf="${suf:+$suf }2>&1"
    }

    # no-verbosity output handling
    [ "$verbosity" = "silent" ] && {
        [ -n "$buildlog" ] || {
            suf=">/dev/null 2>&1"
        }
    }

    # sanitize arguments with quotes
    while [ "$#" -gt 0 ]; do
        argc="$((argc+1))"
        eval "argv$argc=\'\"$1\"\'"
        eval "args=\"\${args:+\$args }\$argv$argc\""
        shift
    done

    # run the command
    [ -n "$buildlog" ] && {
        [ "$printcd" = "y" ] && {
            printf -- "CHANGE_DIRECTORY: $args\n" >>"$buildlog"
        } || {
            printf -- "COMMAND: $cmd $args\n" >>"$buildlog"
        }
    }
    [ "$printcmdline" = "y" ] && printf -- "\033[90m\$\033[0m\033[3m $cmd $args\033[0m\n" >&2

    # run the command and catch errors
    eval "$cmd $args${suf:+ $suf}"
    ec="$?"

    # print an error msg and quit
    [ "$ec" -gt 0 ] && {
        printf -- "${0##*/}: error: failed at \`$cmd $args\`\n" >&2
        exit "$ec"
    }

    # initialize these
    unset cmd argc argv args suf
}
