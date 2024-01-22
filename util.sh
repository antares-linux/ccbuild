#!/bin/sh

# print the help message
print_help() {
    printf "Usage: $0 [OPTIONS]... [TARGET]

Options:
  -c, --cmdline     print relevant commands as they are processed
      --clean       remove all cached tarballs, builds, and logs
  -C, --cleanup     clean up unpacked sources for the current build
      --help        print this message
  -j, --jobs=JOBS   concurrent job/task count
  -l, --log         log build information to ccbuild.log
  -n, --name=NAME   name of the build (default: ccb-TARGET)
  -q, --quieter     reduce output to status messages if printing to a terminal
  -s, --silent      completely disable output if printing to a terminal
  -v, --verbose     enable all terminal output (default)
      --targets     print a list of available targets and exit\n"
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
