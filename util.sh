#!/bin/sh

# print the help message
print_help() {
    printf "Usage: $0 [OPTIONS]... [TARGET]

Options:
  -c, --cmdline         print relevant commands as they are processed
      --clean           remove all cached tarballs, builds, and logs
  -C, --cleanup         clean up unpacked sources for the current build
      --help            print this message
  -j, --jobs=JOBS       concurrent job/task count
  -l, --log             log build information to ccbuild.log
  -n, --name=NAME       name of the build (default: ccb-TARGET)
  -q, --quieter         reduce output to status messages if printing to a terminal
  -s, --silent          completely disable output if printing to a terminal
  -v, --verbose         enable all terminal output (default)
      --targets         print a list of available targets and exit
  -t, --timestamping    enable timestamping\n"
}

# ensure a provided command is installed
require_command() {
    # if it's a script, we're good
    [ -x "$1" ] && return 0

    # check if it's a builtin/alias/$PATH binary
    command -v "$1" >/dev/null 2>&1 || {
        printf "${0##*/}: $1: command not found\n" >&2
        exit 3
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
    printf "$arches\n"
}

# get a timestamp
get_timestamp() {
    # initialize these
    unset time

    # store time
    [ "$has_ns" = "y" ] && {
        time="$(date +%s.%N)"
        eval "${1:+$1_}sec=\"$(printf "$time" | awk -F. '{print $1}')\""
        eval "${1:+$1_}ms=\"$(printf "$time" | awk -F. '{print $2}' | head -c3)\""
        eval "${1:+$1_}time=\"$time\""
    } || {
        eval "${1:+$1_}sec=\"$(date +%s)\""
    }

}

# get timestamp difference
diff_timestamp() {
    # initialize these
    unset ts_diff ts_diff_years ts_diff_months ts_diff_weeks ts_diff_days ts_diff_hours ts_diff_mins ts_diff_sec ts_diff_ms

    # required cmds
    require_command bc awk head

    # pipe args into bc
    ts_diff="$(printf "$1 - $2\n" | bc -ql)"
    ts_diff="${ts_diff#-}"

    # get seconds
    ts_diff_sec="$(printf "$ts_diff" | awk -F. '{print $1}')"
    ts_diff_sec="${ts_diff_sec:-0}"

    # get ms if possible
    ts_diff_ms="$(printf "$ts_diff" | awk -F. '{print $2}' | head -c3)"

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

    # if less than 1 second, use a short prefix
    [ "$ts_diff_sec" -lt 1 >&- 2>&- ] && {
        secondsuffix="s"
    }

    # count the amount of years (lol)
    while [ "$ts_diff_sec" -ge 31557600 ]; do
        ts_diff_sec="$((ts_diff_sec-31557600))"
        ts_diff_years="$((ts_diff_years+1))"
        [ "$ts_diff_years" -ne 1 >&- 2>&- ] yearsuffix="${yearsuffix%s}"
    done

    # count the amount of months
    while [ "$ts_diff_sec" -ge 2628000 ]; do
        ts_diff_sec="$((ts_diff_sec-2628000))"
        ts_diff_months="$((ts_diff_months+1))"
        [ "$ts_diff_months" -ne 1 >&- 2>&- ] monthsuffix="${monthsuffix%s}"
    done

    # count the amount of weeks
    while [ "$ts_diff_sec" -ge 604800 ]; do
        ts_diff_sec="$((ts_diff_sec-604800))"
        ts_diff_weeks="$((ts_diff_weeks+1))"
        [ "$ts_diff_weeks" -ne 1 >&- 2>&- ] weeksuffix="${weeksuffix%s}"
    done

    # count the amount of days
    while [ "$ts_diff_sec" -ge 86400 ]; do
        ts_diff_sec="$((ts_diff_sec-86400))"
        ts_diff_days="$((ts_diff_days+1))"
        [ "$ts_diff_days" -ne 1 >&- 2>&- ] daysuffix="${daysuffix%s}"
    done

    # count the amount of hours
    while [ "$ts_diff_sec" -ge 3600 ]; do
        ts_diff_sec="$((ts_diff_sec-3600))"
        ts_diff_hours="$((ts_diff_hours+1))"
        [ "$ts_diff_hours" -ne 1 >&- 2>&- ] hoursuffix="${hoursuffix%s}"
    done

    # count the amount of minutes
    while [ "$ts_diff_sec" -ge 60 ]; do
        ts_diff_sec="$((ts_diff_sec-60))"
        ts_diff_minutes="$((ts_diff_minutes+1))"
        [ "$ts_diff_minutes" -ne 1 >&- 2>&- ] minutesuffix="${minutesuffix%s}"
    done

    # print the timestamp difference
    printf -- "${ts_diff_years:+$ts_diff_years$yearsuffix, }${ts_diff_months:+$ts_diff_months$monthsuffix, }${ts_diff_weeks:+$ts_diff_weeks$weeksuffix, }${ts_diff_days:+$ts_diff_days$daysuffix, }${ts_diff_hours:+$ts_diff_hours$hoursuffix, }${ts_diff_minutes:+$ts_diff_minutes$minutesuffix, }$ts_diff_sec${ts_diff_ms:+.$ts_diff_ms}$secondsuffix\n"
}

# wrapper function for running commands (for verbosity/logging/etc)
run() {
    # initialize these
    unset cmd argc argv args suf printcd

    # store the command name
    require_command "$1" && cmd="$1" && shift

    # decide what flags to append to commands
    case "${cmd##*/}" in
        mkdir|cp|ln|rm) suf="-v" ;;
                    cd) printcd="y" ;;
    esac

    # commands print what they normally do
    [ "$verbosity" = "quieter" ] && {
        suf=""
        [ -n "$buildlog" ] || {
            case "${cmd##*/}" in
                make|configure) suf=">/dev/null" ;;
            esac
        }
    }

    # output handling
    [ -n "$buildlog" ] && {
        suf="${suf:+$suf }>>'$buildlog' 2>&1"
    } || {
        suf="${suf:+$suf }2>&1"
    }

    # no-verbosity output handling
    [ "$verbosity" = "silent" ] && {
        [ -n "$buildlog" ] && {
            suf="${suf:+$suf }>>'$buildlog' 2>&1"
        } || {
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
            printf "CHANGE_DIRECTORY: $args\n" >>"$buildlog"
        } || {
            printf "COMMAND: $cmd $args\n" >>"$buildlog"
        }
    } || {
        [ "$printcmdline" = "y" ] && printf "\033[90m\$\033[0m\033[3m $cmd $args\033[0m\n" >&2
    }

    # run the command and catch errors
    eval "$cmd $args${suf:+ $suf}" || {
        printf "${0##*/}: error: failed at \`$cmd $args\`\n" >&2
        exit 4
    }

    # initialize these
    unset cmd argc argv args suf
}
