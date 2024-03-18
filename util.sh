#!/bin/sh

# vi: ts=4 sw=4 sts=4 et

# Copyright (C) 2024 Andrew Blue <andy@antareslinux.org>
# Distributed under the terms of the ISC license.
# See the LICENSE file for more information.

# garbage bin file

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
        eval "case \"$_str\" in $_i) return 0 ;; esac"
    done
    return 1
}

# print status messages
printstatus() {
    test "$log_commands" = "y" && return
    test "$verbosity" = "normal" -a -n "$log_file" && printf "%s\n" "$1" >&2
    test "$verbosity" = "quieter" && printf "%s\n" "$1" >&2
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
    dirname="${4:-${name}${version:+-$version}}"
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
    unset _cur_start_time _cur_end_time _cur_time
    read_pkg "$1"
    test -r "$archive" && return 0
    eval "printstatus \"Downloading \${pkg_${1}_link##*/}\""
    test "$timestamping" = "y" && _cur_start="$(get_timestamp)"

    for _i in "aria2c -s \"$JOBS\" -j \"$JOBS\" -o \"$archive\" \"$link\"" \
              "curl -fL# -o \"$archive\" \"$link\"" \
              "wget -O \"$archive\" \"$link\"" \
              "lynx -dump \"$link\" > \"$archive\""
        do has_command "${_i%% *}" && eval "run $_i" && break
    done
    printstatus "Hashing $archive"
    run check_hash "$name" && eval "pkg_${name}_verified=y"

    test "$timestamping" != "y" && return
    _cur_end="$(get_timestamp)"
    _cur_time="$(diff_timestamp "$_cur_start" "$_cur_end")"
    download_time="$(printf "${download_time:+$download_time + }$_cur_time\n" | bc -ql)"
    test -z "${download_time%%.*}" && download_time="0$download_time"
}

# prepare and patch a package for building
prep_pkg() {
    read_pkg "$1"
    [ -r "$CCBROOT/cache/$archive" ] || error "prep_pkg: $name: Package not downloaded"
    eval "test \"pkg_${name}_verified\" != \"y\"" && printstatus "Hashing $archive" && run check_hash "$1"
    printstatus "Opening $archive"
    run tar -xpf "$CCBROOT/cache/$archive"
    test -d "$dirname" || error "$name: $dirname: No such file or directory"
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
    unset _hashcmd _computed_hash _stored_hash
    read_pkg "$1"
    for _i in "$CCBROOT"/hashes/${name}/${archive}.*; do
        has_command "${_i##*/${archive}.}sum" || continue
        _hashcmd="${_i##*/${archive}.}sum"
        _computed_hash="$($_hashcmd "$CCBROOT/cache/$archive")"
        _computed_hash="${_computed_hash%% *}"
        _stored_hash="$(while IFS= read -r line; do printf "$line"; done <"$_i")"
        test "$_computed_hash" = "$_stored_hash" && return
        printf "${_hashcmd}: ${archive}: Hash mismatch or compute failure\n" >&2
        return 1
    done
}

# get a timestamp
get_timestamp() {
    unset _time _sec _ms
    test "$has_ns" = "y" || { printf "$(date +%s)"; return; }
    _time="$(date +%s.%N)"
    _sec="${_time%%.*}"
    _ms="${_time##*.}"
    _ms="${_ms%"${_ms#???}"}"
    printf "$_sec.$_ms"
}

# compare timestamps
diff_timestamp() {
    unset _ts _sec _ms
    _ts="$(printf "${2:+$2 - $1 - }0\n" | bc -ql)"
    _sec="${_ts%%.*}"
    _ms="${_ts##*.}"
    _ms="${_ms%"${_ms#???}"}"
    printf "${_sec:-0}${_ms:+.$_ms}"
}

# format a timestamp string
fmt_timestamp() {
    unset _time _days _hours _minutes _seconds _miliseconds
    _time="${1:-0}"
    _seconds="${_time%%.*}"
    _miliseconds="${_time##$_seconds}"
    _miliseconds="${_miliseconds#.}"
    daysuffix="$(if str_match "$time_fmt" 's'; then printf "d"; else printf " days"; fi)"
    hoursuffix="$(if str_match "$time_fmt" 's'; then printf "h"; else printf " hours"; fi)"
    minutesuffix="$(if str_match "$time_fmt" 's'; then printf "m"; else printf " minutes"; fi)"
    secondsuffix="$(if str_match "$time_fmt" 's'; then printf "s"; else printf " seconds"; fi)"

    while [ "$_seconds" -ge 86400 ]; do _seconds="$((_seconds-86400))"; _days="$((_days+1))"; done
    test "$_days" -ne 1 >&- 2>&- || daysuffix="${daysuffix%s}"
    while [ "$_seconds" -ge 3600 ]; do _seconds="$((_seconds-3600))"; _hours="$((_hours+1))"; done
    test "$_hours" -ne 1 >&- 2>&- || hoursuffix="${hoursuffix%s}"
    while [ "$_seconds" -ge 60 ]; do _seconds="$((_seconds-60))"; _minutes="$((_minutes+1))"; done
    test "$_minutes" -ne 1 >&- 2>&- || minutesuffix="${minutesuffix%s}"
    test "$_seconds" -ne 1 >&- 2>&- || test -n "$_miliseconds" || test "$_secondprefix" = "s" || secondsuffix="${secondsuffix%s}"
    test "$_seconds" -lt 1 >&- 2>&- && secondsuffix="s"
    printf "${_days:+$_days$daysuffix, }${_hours:+$_hours$hoursuffix, }${_minutes:+$_minutes$minutesuffix, }$_seconds${_miliseconds:+.$_miliseconds}$secondsuffix\n"
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
