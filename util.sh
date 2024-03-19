#!/bin/sh

# vi: ts=4 sw=4 sts=4 et

# Copyright (C) 2024 Andrew Blue <andy@antareslinux.org>
# Distributed under the terms of the ISC license.
# See the LICENSE file for more information.

# garbage bin file

# help message
print_help() { printf "\
Usage: $0 [OPTIONS]... [TARGET]\n\nOptions:
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
  -v, --verbose             enable all command output (default)\n
Features:\n  'atomic',\n  'cxx',\n  'ffi',\n  'fortran',\n  'itm',\n  'lto',\n  'openmp',\n  'phobos',\n  'quadmath',\n  'ssp',\n  'vtv'\n"
}

# exit and print an error
error() {
    printf "${0##*/}: error: %s\n" "$1" >&2
    exit "${2:-1}"
}

# case statement wrapper
str_match() {
    _str="$1"
    shift
    for _i in "$@"; do eval "case \"$_str\" in $_i) return 0 ;; esac"; done
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
    test -n "$1" || error "read_pkg: No package name specified"
    eval "test -n \"\$pkg_${1}_name\"" || error "read_pkg: Package $1 has not been defined"
    eval "name=\"\$pkg_${1}_name\"; version=\"\$pkg_${1}_version\"; link=\"\$pkg_${1}_link\"; archive=\"\$pkg_${1}_archive\"; dirname=\"\$pkg_${1}_dirname\"; patchpaths=\"\$pkg_${1}_patchpaths\""
}

# set variabless containing info about a package
def_pkg() {
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
        [ -d "$_i" ] && eval "pkg_${name}_patchpaths=\"\${pkg_${name}_patchpaths:+\$pkg_${name}_patchpaths }$_i\""
    done
}

# download a package
get_pkg() {
    read_pkg "$1"
    test -r "$archive" && return 0
    eval "printstatus \"Downloading \${pkg_${1}_link##*/}\""
    test "$timestamping" = "y" && _cur_start="$(get_timestamp)"
    for _i in "aria2c -s \"$JOBS\" -j \"$JOBS\" -o \"$archive\" \"$link\""    "curl -fL# -o \"$archive\" \"$link\""    "wget -O \"$archive\" \"$link\""    "lynx -dump \"$link\" > \"$archive\""; do
        command -v "${_i%% *}" >/dev/null 2>&1 && eval "run $_i" && break
    done
    printstatus "Hashing $archive"
    run check_hash "$name"
    test "$timestamping" != "y" && return
    _cur_end="$(get_timestamp)"
    _cur_time="$(diff_timestamp "$_cur_start" "$_cur_end")"
    download_time="$(printf "${download_time:+$download_time + }$_cur_time\n" | bc -ql)"
    test -z "${download_time%%.*}" && download_time="0$download_time"
}

# prepare and patch a package for building
prep_pkg() {
    read_pkg "$1"
    test -r "$CCBROOT/cache/$archive" || error "prep_pkg: $name: Package not downloaded"
    eval "test \"pkg_${name}_verified\" != \"y\"" && printstatus "Hashing $archive" && run check_hash "$1"
    printstatus "Opening $archive"
    run tar -xpf "$CCBROOT/cache/$archive"
    test -n "$patchpaths" || return
    test -d "$dirname" || error "$name: $dirname: No such file or directory"
    printstatus "Patching $name${version:+-$version}"
    for _i in $patchpaths; do
        test -d "$_i"           && for _j in $_i/*.patch $_i/*.diff; do test -r "$_j" && { cd "$dirname"; run patch -p0 -i "$_j"; cd ..; }; done
        test -d "$_i/$CPU_NAME" && for _k in $_i/*.patch $_i/*.diff; do test -r "$_k" && { cd "$dirname"; run patch -p0 -i "$_k"; cd ..; }; done
    done
}

# check hashes for downloaded files
check_hash() {
    read_pkg "$1"
    for _i in "$CCBROOT"/hashes/${name}/${archive}.*; do
        command -v "${_i##*/${archive}.}sum" >/dev/null 2>&1 || continue
        str_match "$(${_i##*/${archive}.}sum "$CCBROOT/cache/$archive")" "$(while IFS= read -r line; do printf "$line*"; done <"$_i")" && eval "pkg_${name}_verified=y" && return
        printf "${_i##*/${archive}.}sum: ${archive}: Hash mismatch or compute failure\n" >&2; return 1
    done
}

# get a timestamp
get_timestamp() {
    test "$(date +%N)" = "%N" && { printf "$(date +%s)"; return; }
    _time="$(date +%s.%N)"
    _ms="${_time##*.}"
    printf "${_time%%.*}.${_ms%"${_ms#???}"}"
}

# compare timestamps
diff_timestamp() {
    _ts="$(printf "${2:+$2 - $1 - }0\n" | bc -ql)"
    _sec="${_ts%%.*}"
    printf "${_sec:-0}${_ts##$_sec}"
}

# format a timestamp string
fmt_timestamp() {
    _seconds="${1%%.*}"
    _miliseconds="${1##$_seconds}"
    _days="$((_seconds / 86400))"
    _seconds="$((_seconds % 86400))"
    _hours="$((_seconds / 3600))"
    _seconds="$((_seconds % 3600))"
    _minutes="$((_seconds / 60))"
    _seconds="$((_seconds % 60))"
    _seconds="$_seconds$_miliseconds"
    printf "$(test "$_days" -gt 0 && printf "%%d%%s%%s%%s")" "$_days" "$(if test "$time_fmt" = "s"; then printf "d"; else printf " day"; fi)" "$(test "$_days" != "1" -a "$time_fmt" != "s" && printf "s")" "$(test "$_hours" = "0" -a "$_minutes" = "0" -a "$_seconds" = "0" || printf ", ")"
    printf "$(test "$_hours" -gt 0 && printf "%%d%%s%%s%%s")" "$_hours" "$(if test "$time_fmt" = "s"; then printf "h"; else printf " hour"; fi)" "$(test "$_hours" != "1" -a "$time_fmt" != "s" && printf "s")" "$(test "$_minutes" = "0" -a "$_seconds" = "0" || printf ", ")"
    printf "$(test "$_minutes" -gt 0 && printf "%%d%%s%%s%%s")" "$_minutes" "$(if test "$time_fmt" = "s"; then printf "h"; else printf " minute"; fi)" "$(test "$_minutes" != "1" -a "$time_fmt" != "s" && printf "s")" "$(test "$_seconds" = "0" -a "$_seconds" = "0" || printf ", ")"
    printf "$(test "$_seconds" != "0" && printf "%%s%%s%%s")" "$_seconds" "$(if test "$time_fmt" = "s" -o "${_seconds%%.*}" = "0"; then printf "s"; else printf " second"; fi)" "$(test "$_seconds" != "1" -a "$_seconds" != "1.000" -a "${_seconds%%.*}" != "0" -a "$time_fmt" != "s" && printf "s")"
}

# gaaabag been
run() {
    command -v "$1" >/dev/null || error "$1: command not found" 127; cmd="$1"; shift
    str_match "${cmd##*/}" 'mkdir|cp|ln|rm|curl|mv|tar' && suf="-v" || suf=""
    test "$verbosity" = "quieter" -a -z "$log_file" && \
        if str_match "${cmd##*/}" 'make|configure|wget|aria2c|patch'; then suf=">/dev/null"; else unset suf; fi
    test -n "$log_file" && \
        if str_match "${cmd##*/}" 'rm|tar'; then suf=">/dev/null 2>>'$log_file'"; else suf="${suf:+$suf }>>'$log_file' 2>&1"; fi
    test -z "$log_file" && suf="${suf:+$suf }2>&1"
    test "$verbosity" = "silent" -a -n "$log_file" && suf=">/dev/null 2>&1"
    test -n "$log_file" && str_match "${cmd##*/}" 'cd|pushd|popd' && printf "CHANGE_DIRECTORY: $*\n" >>"$log_file"
    test -n "$log_file" && ! str_match "${cmd##*/}" 'cd|pushd|popd' && printf "COMMAND: $cmd $*\n" >>"$log_file"
    test "$log_commands" = "y" && printf "\033[90m\$\033[0m\033[3m $cmd $*\033[0m\n" >&2
    eval "$cmd \"\$@\"${suf:+ $suf}" || error "failed at \`$cmd $*\`" "$?"
}
