#!/bin/sh

# vi: ts=4 sw=4 sts=4 et

# Copyright (C) 2024 Andrew Blue <andy@antareslinux.org>
# Distributed under the terms of the ISC license.
# See the LICENSE file for more information.

# garbage bin file

# a few shells don't have this; in our case, variables just need to be emptied
# rather than undefined so this backup fills that role
_unset() {
    unalias unset
    has_command unset && {
        unset "$@"
        alias unset="_unset"
        return
    }
    alias unset="_unset"
    for _i in "$@"; do
        eval "$_i=\"\""
    done
}

alias unset="_unset"

# help message
print_help() {
    printf "\
Usage: $0 [OPTIONS]... [TARGET]

Options:
      --clean               remove all cached tarballs, builds, and logs
  -c, --cmdline             print commands as they are processed
  +c, --no-cmdline          don't print commands as they are processed
  -C, --cleanup             clean \$bdir/src when the build ends
  +C, --no-cleanup          don't clean \$bdir/src when the build ends
      --enable-FEATURE      enable (acquire and build) FEATURE
      --disable-FEATURE     disable (don't acquire and build) FEATURE
  -h, --help                print this message
  -j, --jobs=JOBS           concurrent job/task count
  -l, --log[=FILE]          log compiler output in FILE or ccbuild.log
  +l, --no-log              don't log compiler output in FILE or ccbuild.log
  -n, --name=NAME           name of the build (default: ccb-CPU_NAME)
  -q, --quieter             reduce output if printing to a terminal
  -s, --silent              completely disable output if printing to a terminal
      --shell               spawn a subshell when the build finishes
      --targets             print a list of available targets and exit
      --time-fmt=CHAR       whether to use 'l'ong or 's'hort time units
  -v, --verbose             enable all command output (default)

Features:
  'atomic',\n  'backtrace',\n  'cxx',\n  'ffi',\n  'fortran',\n  'itm',
  'lto',\n  'openmp',\n  'phobos',\n  'quadmath',\n  'ssp',\n  'vtv'\n"
}

# exit and print an error
error() {
    printf "${0##*/}: error: %s\n" "$1" >&2
    exit "${2:-1}"
}

# check if a command is installed
has_command() {
    while [ "$#" -gt 0 ]; do
        test -x "$1" && shift && continue
        command -v "$1" >/dev/null 2>&1 || return 1
        shift
    done
    return 0
}

# cry if a command is not installed
needs_command() {
    for _i in "$@"; do
        has_command "$_i" && continue
        error "$_i: command not found" 3
    done
}

# case statement wrapper
str_match() {
    _str="$1"
    shift
    for _i in "$@"; do
        set -f
        eval "case \"$_str\" in $_i) set +f; return 0 ;; esac"
        set +f
    done
    return 1
}

# print status messages
printstatus() {
    test "$log_commands" = "y" && return
    test "$verbosity" = "normal" -a -n "$log_file" && printf "%s\n" "$1" >&2
    test "$verbosity" = "quieter" && printf "%s\n" "$1" >&2
}

# print a list of the non-symbolic files in ./arch/ (kinda useful)
list_targets() {
    for _i in "$CCBROOT"/arch/*.conf; do
        test -L "$_i" && continue
        i="${i%%.conf}"
        printf "${i##*/} "
    done
    printf "\n"
}

# exit by ending the build
ccb_exit() {
    run cd "$bdir"
    test "$spawn_shell" = "y" && HISTFILE="$CCBROOT/shell_history.txt" eval "${SHELL:-/bin/sh}"
    test -d "$bdir/_tmp" && run rm -rf "$bdir/_tmp"
    test -d "$bdir/src"  && test "$clean_src" = "y" && run rm -rf "$bdir/src"
    test "$timestamping" = "y" && get_timestamp end
    printf "Successfully built for $CPU_NAME/musl (${bdir##$CCBROOT/})" >&2
    test -n "$end_time"      && printf " in $(fmt_timestamp $(diff_timestamp "$start_time" "$end_time"))" >&2
    test -n "$download_time" && printf " ($(fmt_timestamp "$download_time") spent downloading)" >&2
    printf "\n" >&2
    exit
}

# read package vars
read_pkg() {
    unset name version link archive dirname patchpaths
    test -n "$1" || error "read_pkg: No package name specified"
    eval "test -n \"\$pkg_${1}_name\"" || error "read_pkg: Package $1 has not been defined"
    eval "name=\"\$pkg_${1}_name\""
    eval "version=\"\$pkg_${1}_version\""
    eval "link=\"\$pkg_${1}_link\""
    eval "archive=\"\$pkg_${1}_archive\""
    eval "dirname=\"\$pkg_${1}_dirname\""
    eval "patchpaths=\"\$pkg_${1}_patchpaths\""
}

# set variabless containing info about a package
def_pkg() {
    unset name version link archive dirname patchpaths
    test -z "$1" && error "def_pkg: No package name specified"

    name="$1"
    eval "pkg_${name}_name=\"$name\""
    version="$2"
    eval "pkg_${name}_version=\"$version\""
    test -z "$3" && error "def_pkg: No package link specified"
    link="$3"
    eval "pkg_${name}_link=\"$link\""
    dirname="${4:-${name}-${version}}"
    eval "pkg_${name}_dirname=\"$dirname\""
    archive="${5:-${3##*/}}"
    eval "pkg_${name}_archive=\"$archive\""

    for _i in "$CCBROOT/patches/${name}" "$CCBROOT/patches/${name}/${version}" "$CCBROOT/patches/${name}-${version}"; do
        [ -d "$_i" ] && patchpaths="${patchpaths:+$patchpaths }$_i"
    done
    eval "pkg_${name}_patchpaths=\"$patchpaths\""
}

# download a package
get_pkg() {
    unset name version link archive dirname patchpaths
    unset current_download_start_time current_download_end_time current_download_time

    read_pkg "$1"
    test -r "$archive" && return 0
    eval "printstatus \"Downloading \${pkg_${1}_link##*/}\""
    test "$timestamping" = "y" && get_timestamp current_download_start

    for _i in "aria2c -s \"$JOBS\" -j \"$JOBS\" -o \"$archive\" \"$link\"" \
             "curl -fL# -o \"$archive\" \"$link\"" \
             "wget -O \"$archive\" \"$link\"" \
             "lynx -dump \"$link\" > \"$archive\""
        do has_command "${i%% *}" && eval "run $_i" && break
    done
    check_hash "$1" && eval "pkg_${name}_verified=y"

    test "$timestamping" != "y" && return
    get_timestamp current_download_end
    current_download_time="$(diff_timestamp "$current_download_start_time" "$current_download_end_time")"
    download_time="$(printf "${download_time:+$download_time + }$current_download_time\n" | bc -ql)"
    test -z "${download_time%%.*}" && download_time="0$download_time"
}

# prepare and patch a package for building
prep_pkg() {
    read_pkg "$1"
    [ -r "$CCBROOT/cache/$archive" ] || error "prep_pkg: $name: Package not downloaded"
    eval "test \"pkg_${name}_verified\" != \"y\"" && check_hash "$1"
    printstatus "Opening $archive"
    run tar -xpf "$CCBROOT/cache/$archive"
    run test -d "$dirname"
    cd "$dirname"

    test -n "$patchpaths" || { cd ..; return; }
    printstatus "Patching $name-$version"
    for _i in $patchpaths; do
        test -d "$_i" && for _j in $_i/*.patch $_i/*.diff; do
            [ -r "$_j" ] && run patch -p0 -i "$_j"
        done
        test -d "$_i/$CPU_NAME" && for _k in $_i/*.patch $_i/*.diff; do
            [ -r "$_k" ] && run patch -p0 -i "$_k"
        done
    done
    cd ..
}

# check hashes for downloaded files
check_hash() {
    unset hashcmd computed_hash stored_hash
    read_pkg "$1"
    printstatus "Hashing $archive"
    for _i in "$CCBROOT"/hashes/${name}/${archive}.*; do
        has_command "${i##*/${archive}.}sum" || continue
        hashcmd="${i##*/${archive}.}sum"
        computed_hash="$($hashcmd "$CCBROOT/cache/$archive")"
        computed_hash="${computed_hash%% *}"
        stored_hash="$(while IFS= read -r line; do printf "$line"; done <"$_i")"
        test "$computed_hash" = "$stored_hash" || error "${hashcmd}: ${archive}: Hash mismatch or compute failure"
        break
    done
}

# get a timestamp
get_timestamp() {
    test "$has_ns" = "y" && eval "${1:+$1_}time=\"$(date +%s.%N)\"" && return
    eval "${1:+$1_}time=\"$(date +%s)\""
}

# get the difference between two timestamps
diff_timestamp() {
    unset ts_diff ts_diff_sec ts_diff_ms
    ts_diff="$(printf "$2 - $1\n" | bc -ql)"
    ts_diff="${ts_diff#-}"
    ts_diff="${ts_diff%.}"

    : "${ts_diff_sec:=${ts_diff%%.*}}"
    : "${ts_diff_sec:=0}"
    test "$ts_diff" = "$ts_diff_sec" && printf "$ts_diff_sec" && return

    ts_diff_ms="${ts_diff##*.}"
    ts_diff_ms="${ts_diff_ms%"${ts_diff_ms#???}"}"
    printf "$ts_diff_sec${ts_diff_ms:+.$ts_diff_ms}"
}

# format a timestamp string
fmt_timestamp() {
    unset time seconds miliseconds years months weeks days hours minutes
    time="${1:-0}"
    seconds="${time%%.*}"
    miliseconds="${time##$seconds}"
    miliseconds="${miliseconds#.}"
    daysuffix="$(if str_match "$time_fmt" 's'; then printf "d"; else printf " days"; fi)"
    hoursuffix="$(if str_match "$time_fmt" 's'; then printf "h"; else printf " hours"; fi)"
    minutesuffix="$(if str_match "$time_fmt" 's'; then printf "m"; else printf " minutes"; fi)"
    secondsuffix="$(if str_match "$time_fmt" 's'; then printf "s"; else printf " seconds"; fi)"

    while [ "$seconds" -ge 86400 ]; do seconds="$((seconds-86400))"; days="$((days+1))"; done
    test "$days" -ne 1 >&- 2>&- || daysuffix="${daysuffix%s}"
    while [ "$seconds" -ge 3600 ]; do seconds="$((seconds-3600))"; hours="$((hours+1))"; done
    test "$hours" -ne 1 >&- 2>&- || hoursuffix="${hoursuffix%s}"
    while [ "$seconds" -ge 60 ]; do seconds="$((seconds-60))"; minutes="$((minutes+1))"; done
    test "$minutes" -ne 1 >&- 2>&- || minutesuffix="${minutesuffix%s}"
    test "$seconds" -ne 1 >&- 2>&- || test -n "$miliseconds" || test "$secondprefix" = "s" || secondsuffix="${secondsuffix%s}"
    test "$seconds" -lt 1 >&- 2>&- && secondsuffix="s"
    printf "${days:+$days$daysuffix, }${hours:+$hours$hoursuffix, }${minutes:+$minutes$minutesuffix, }$seconds${miliseconds:+.$miliseconds}$secondsuffix\n"
}

# gaaabag been
run() {
    unset cmd suf printcd ec
    needs_command "$1" && cmd="$1" && shift
    str_match "${cmd##*/}" 'mkdir|cp|ln|rm|curl|mv|tar' && suf="-v"
    str_match "${cmd##*/}" 'cd|pushd|popd' && printcd="y"
    test "$verbosity" = "quieter" -a -z "$log_file" && \
        if str_match "${cmd##*/}" 'make|configure|wget|aria2c|patch'; then suf=">/dev/null"; else unset suf; fi
    test -n "$log_file" && \
        if str_match "${cmd##*/}" 'rm|tar'; then suf=">/dev/null 2>>'$log_file'"; else suf="${suf:+$suf }>>'$log_file' 2>&1"; fi

    test -z "$log_file" && suf="${suf:+$suf }2>&1"
    test "$verbosity" = "silent" -a -n "$log_file" && suf=">/dev/null 2>&1"
    test -n "$log_file" -a "$printcd" = "y" && printf "CHANGE_DIRECTORY: $*\n" >>"$log_file"
    test -n "$log_file" -a "$printcd" != "y" && printf "COMMAND: $cmd $*\n" >>"$log_file"
    test "$log_commands" = "y" && printf "\033[90m\$\033[0m\033[3m $cmd $*\033[0m\n" >&2
    eval "$cmd \"\$@\"${suf:+ $suf}"
    test "${ec:=$?}" -gt "0" && error "failed at \`$cmd $*\`" "$ec"
}
