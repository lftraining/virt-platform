#!/bin/bash
##############################################################################
# Written by: Behan Webster
# Licensed under the GPLv2
#
# Clean an image before making it a template
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

APT="verbose apt-get"
SED="verbose sed -E"

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
add_after() {
	local FILE=${1:?} LINE=${2:?} AFTER=${3:-$}

	[[ -e $FILE ]] || touch "$FILE"
	if ! grep -q "^$LINE$" "$FILE" ; then
		$SED -i "$FILE" -e "${AFTER}a $LINE"
	fi
}

################################################################################
#DIST="bullseye"
RMPKGS="apt-listchanges debian-faq doc-debian"

ADDPKGS="byobu cloud-utils debfoster lsof mosh nfs-common openssh-server
	qemu-guest-agent rsync sudo terminator vim vim-scripts vim-addon-manager vim-youcompleteme"
KERNELPKGS="bc bison build-essential flex libelf-dev libssl-dev lz4"

# Make sure to not check the CDROM for packages since it is unmounted
$SED -i /etc/apt/sources.list -e '/^deb cdrom/d'

# Do all the package stuff
export DEBIAN_FRONTEND=noninteractive
$APT update
# shellcheck disable=SC2086
$APT -y install $ADDPKGS $KERNELPKGS
verbose vim-addons install youcompleteme
# shellcheck disable=SC2086
$APT -y purge $RMPKGS
$APT -y autoremove
dpkg -l | awk '/^rc/ {print $2}' | xargs -r dpkg --purge
$APT -y full-upgrade

# Update sudo 
USERNAME="student"
add_after "/etc/sudoers.d/$USERNAME" "$USERNAME ALL=(ALL) NOPASSWD:ALL" 

# Auto login the GUI
$SED -i /etc/gdm3/daemon.conf -e \
	"s/^.*(AutomaticLoginEnable =).*$/\\1 true/;
	s/^.*(AutomaticLogin =).*$/\\1 $USERNAME/;"

# Set up NFS share
IP="10.10.10.1"
SERVER="proxmox"
SHARE="/srv/LFT"
add_after "/etc/hosts" "$IP	$SERVER"
#grep -q "$SERVER:$SHARE" /etc/fstab || echo "$SERVER:$SHARE $SHARE nfs soft 0 0" >>/etc/fstab
add_after "/etc/fstab" "$SERVER:$SHARE $SHARE nfs soft 0 0"
verbose mkdir -p "$SHARE"
verbose mount "$SHARE"

# Need to manually disable screen locking :(
#systemctl restart gdm
#gsettings set org.gnome.desktop.lockdown disable-lock-screen true
