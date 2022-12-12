#!/bin/bash
##############################################################################
# Written by: Behan Webster
# Licensed under the GPLv2
#
# Clean an image and shutdown before making it a template
#

set -u
set -e

VERSION=1.0

TEST="${TEST:+echo}"

RED="\e[0;31m"
GREEN="\e[0;32m"
#YELLOW="\e[0;33m"
CYAN="\e[0;36m"
#BLUE="\e[0;34m"
BACK="\e[0m"

################################################################################
info() {
	echo -e "${GREEN}I:" "$@" "$BACK" >&2
}

################################################################################
error() {
	echo -e "${RED}E:" "$@" "$BACK" >&2
	exit 1
}

################################################################################
verbose_cmd() {
	echo -e "$CYAN+" "$@" "$BACK" >&2
}

################################################################################
verbose() {
	verbose_cmd "$@"
	if [[ -z ${TEST:-} ]] ; then
		"$@"
	fi
}

################################################################################
run_if_in_path() {
	if command -v "${1:?}" &>/dev/null ; then
		verbose "$@"
	fi
}

################################################################################
remove() {
	verbose rm -rf "$@"
}

################################################################################
truncate() {
	if [[ -f $1 ]] ; then
		verbose_cmd "Truncate $1"
		if [[ -z ${TEST:-} ]] ; then
			>"$1"
		fi
	fi
}

################################################################################
upgrade_packages() {
	verbose apt-get update
	verbose apt-get -y full-upgrade
}

################################################################################
clean_packages() {
	[[ $# -eq 0 ]] || verbose apt-get -y purge "$@"
	verbose apt-get -y autoremove --purge
	verbose apt-get -y clean
	verbose apt-get -y autoclean
}

################################################################################
clean_ids() {
	run_if_in_path cloud-init clean
	truncate /etc/machine-id
	truncate /var/lib/dbus/machine-id
	run_if_in_path fstrim --all
}

################################################################################
clean_logs() {
	local LOG

	verbose systemctl stop rsyslog.service systemd-journald.service

	for LOG in /var/log/* ; do
		case "$LOG" in
			*.1|*.gz) remove "$LOG" ;;
			*/apt|*/journal|*/lighttpd|*/pihole|*/private) remove "$LOG"/* ;;
			*.log|*/debug|*/mail.*|*/messages|*/syslog) truncate "$LOG" ;;
			*/btmp|*/faillog|*/lastlog|*/utmp|*/wtmp) truncate "$LOG" ;;
		esac
	done
}

################################################################################
clean_history() {
	local FILE
	while read -r FILE ; do
		truncate "$FILE"
	done <<<"$(find /root /home -maxdepth 1 -name .bash_history)"
}

################################################################################
export DEBIAN_FRONTEND=noninteractive
upgrade_packages
clean_packages
clean_ids
clean_logs
clean_history
sync

verbose shutdown -h now
