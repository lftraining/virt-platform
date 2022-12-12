#!/bin/bash
##############################################################################
# Written by: Behan Webster
# Licensed under the GPLv2
#
# Install proxmox on new Debian install
#

set -e

VERSION=1.0

RED="\e[0;31m"
GREEN="\e[0;32m"
YELLOW="\e[0;33m"
#CYAN="\e[0;36m"
#BLUE="\e[0;34m"
BACK="\e[0m"

VERBOSE=

MKDIR="verbose mkdir -p"
GIT="verbose git"
#RM="verbose rm -f"
#SED="verbose sed"

##############################################################################
verbose() {
	if [[ -n $TEST ]] ; then
		echo + "$@" >&2
	elif [[ -n $VERBOSE ]] ; then
		(set -x; "$@")
	else
		"$@"
	fi
}

##############################################################################
info() {
	echo -e "${GREEN}I:" "$@" "$BACK" >&2
}

##############################################################################
banner() {
	echo -e "${GREEN}##############################################################################$BACK" >&2
	info "$@"
}

##############################################################################
warn() {
	echo -e "${YELLOW}W:" "$@" "$BACK" >&2
}

##############################################################################
error() {
	echo -e "${RED}E:" "$@" "$BACK" >&2
	verbose exit 1
}

################################################################################
in_path() {
	command -v "$@" >/dev/null 2>&1
}

##############################################################################
default_config() {
	unset LC_TERMINAL
	unset LC_CTYPE
	LANG=C

	TEST="${TEST:+echo}"
	NFS="/srv/LFT"
	
	# Fast google kernel.org mirror
	KERNELSRC="https://kernel.googlesource.com/pub/scm/linux/kernel/git/stable/linux-stable"
	KERNELDIR="$NFS/linux-stable"
}

##############################################################################
read_config() {
	default_config
	
	banner "Read Configuration"

	local CONF FILES="$HOME/.config/install-proxmox/defaults.conf $HOME/.install-proxmox.conf"	
	for CONF in $FILES ; do
		if [[ -f "$CONF" ]] ; then
			# shellcheck disable=SC1090
			. "$CONF"
		fi
	done
}

##############################################################################
run_apt() {
	DEBIAN_FRONTEND=noninteractive verbose apt-get --quiet --assume-yes --no-install-recommends "$@"
}

##############################################################################
update_debian() {
	banner "Update Debian packages"
	run_apt update
	run_apt full-upgrade
}

##############################################################################
install_debian_extras() {
	banner "Install extra Debian packages"
	run_apt install mosh rsync vim vim-youcompleteme

	verbose vim-addons install youcompleteme

	banner "Install Debian kernel packages"
	run_apt install bc bison build-essential flex libelf-dev libssl-dev lz4

}

##############################################################################
check_debian() {
	update_debian
	install_debian_extras
}

##############################################################################
latest_branch() {
	$GIT branch -a | sed -E '/linux-[0-9]/!d; s|^.*/||; s/^.* //;' | sort -n -t - -k2 -k3 | tail -1
}

##############################################################################
latest_tag() {
	$GIT tag | sed -E '/^v/!d; /-rc/d; s/^v//;' | sort -n -t . -k1 -k2 -k3 | tail -1 | sed 's/^/v/'
}

##############################################################################
clone_kernel() {
	$MKDIR "${KERNELDIR%/*}"
	if [[ ! -d $KERNELDIR ]] ; then
		$GIT clone "$KERNELSRC" "$KERNELDIR"
	fi
	cd "$KERNELDIR"
	$GIT checkout "$(latest_tag)"
}

##############################################################################
welcome() {
	banner "visit https://$(get_ip):8006/ in your browser"
	info "Login as root, password $PASSWORD, and Realm set to 'Linux PAM standard authentication'"
}

##############################################################################
do_the_thing() {
	check_debian
	clone_kernel
	#welcome
}

##############################################################################
usage() {
	cat <<END
Version $VERSION
Usage: ${0##*/} [options] [steps]
	-n|--dry-run	Dry-run of script
	-V|--version	Version of script
	-h|--help	This help
END
exit 1
}

##############################################################################
# Read options
read_config
while [[ $1 =~ ^- ]] ; do
	# shellcheck disable=SC2086
	case "$1" in
		--list) sed -n '/^do_the_thing()/,/^\}$/{//!p;}' $0; exit 0;;
		-n|--dry-run|--test) TEST="echo";;
		--trace) set -x;;
		-v|--verbose) VERBOSE=1;;
		-V|--version) echo $VERSION; exit 0;;
		--) break;;
		-*) usage;;
	esac
	shift
done

##############################################################################
if [[ $# -gt 0 ]] ; then
	while [[ $# -gt 0 ]] ; do
		"$1"
		shift
	done
else
	time do_the_thing
fi
