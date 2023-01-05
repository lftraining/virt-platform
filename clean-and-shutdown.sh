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

APT="verbose apt-get -y"
DD="verbose dd"
MKSWAP="verbose mkswap"

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
	verbose rm -rf "${@:?}"
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
	info "Upgrade packages"
	$APT update
	$APT full-upgrade
}

################################################################################
get_old_kernels() {
	ls /boot/vmlinuz-* | sed -E -e 's|^.*vmlinuz-(.*)-[^-]+|\1|; $d'
}

################################################################################
clean_kernels() {
	local KERNS
	KERNS="$(get_old_kernels)"
	info "Cleaning up old kernels"

	if [[ $KERNS =~ $(uname -r) ]] ; then
		error "Not running the latest kernel. Reboot and run this again"
	fi

	$APT purge $KERNS
}

################################################################################
clean_packages() {
	[[ $# -eq 0 ]] || $APT purge "$@"
	info "Cleaning up packages"
	$APT autoremove --purge
	$APT clean
	$APT autoclean
	remove /var/cache/*
}

################################################################################
# Zero out and reformat the swap partition or file
clean_swaps(){
	local SWAPS SWAPSLOT
	SWAPS="$(sed '1d; s| .*$||;' /proc/swaps)"
	info "Swap Partitions or file are: $SWAPS"

	verbose swapoff -a
	for SWAPSLOT in $SWAPS ; do
		if [[ $SWAPSLOT =~ zram  ]] ; then
			warn "SKIPPING zram device: $SWAPSLOT"
		elif [[ $SWAPSLOT =~ /dev/ ]] ; then
			local UUID LABEL
			UUID=$(blkid -s UUID -o value $SWAPSLOT)
			LABEL=$(blkid -s LABEL -o value $SWAPSLOT)

			info "Clearing $SWAPSLOT, LABEL=$LABEL, UUID=$UUID "
			$DD if=/dev/zero of="$SWAPSLOT" bs=1M

			$MKSWAP -U "$UUID" ${LABEL:+-L $LABEL} "$SWAPSLOT"
		else
			local SIZE SIZEMB
			info "Clearing $SWAPSLOT"
			SIZE="$(stat -c%s "$SWAPSLOT")"
			SIZEMB="$(( SIZE / 1024 / 1024 ))"
			info "Clearing $SWAPSLOT with a new file of size $SIZEMB MB"
			remove "$SWAPSLOT"
			$DD if=/dev/zero of="$SWAPSLOT" bs=1M count="$SIZEMB"
			verbose chmod 600 "$SWAPSLOT"
			$MKSWAP "$SWAPSLOT"
		fi
	done
}

################################################################################
clean_files() {
	local FILES
	info "Cleaning up files and caches"
	FILES=$(
		find /home /root -maxdepth 4 -name .cache -o -name .ccache | xargs --no-run-if-empty echo
		find /var/tmp -mindepth 1 -maxdepth 1 | xargs --no-run-if-empty echo
	)
	remove $FILES
}

################################################################################
clean_ids() {
	info "Remove machine ids"
	run_if_in_path cloud-init clean
	truncate /etc/machine-id
	truncate /var/lib/dbus/machine-id
	run_if_in_path fstrim --all
}

################################################################################
clean_logs() {
	local LOG

	info "Clean up log files"
	verbose journalctl --vacuum-time=1d
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
	info "Remove history"
	while read -r FILE ; do
		truncate "$FILE"
	done <<<"$(find /root /home -maxdepth 1 -name .bash_history)"
}

################################################################################
export DEBIAN_FRONTEND=noninteractive
upgrade_packages
clean_kernels
clean_packages
#clean_swaps
clean_files
clean_ids
clean_logs
clean_history
sync

verbose shutdown -h now
