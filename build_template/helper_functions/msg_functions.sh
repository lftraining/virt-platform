#!/bin/bash

RED="\e[0;31m"
GREEN="\e[0;32m"
BACK="\e[0m"

#######
# General messaging helper functions
#

msg_is_present() { echo "msg functions present"; }

info() {
	echo -e "${GREEN}I:" "=== $@ ===" "$BACK" >&2
}

error() {
	echo -e "${RED}E:" "$@" "$BACK" >&2
	exit 1
}

disp_n_call() {
	local code

	echo "about to call: $@"
	"$@"
        code=$?
        if [[ $code -ne 0 ]]; then
                echo "$1 got an error (code: $code), exiting"
                exit $code
        fi
}
