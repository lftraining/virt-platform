#!/bin/bash
##############################################################################
# Written by: Behan Webster
# Licensed under the GPL
#
# Download ISOs for proxmox environment
#

set -e

VERSION=1.0

#RED="\e[0;31m"
GREEN="\e[0;32m"
#YELLOW="\e[0;33m"
#CYAN="\e[0;36m"
#BLUE="\e[0;34m"
BACK="\e[0m"

VERBOSE=

MKDIR="verbose mkdir -p"
WGET="verbose wget --continue --quiet --show-progress --progress=bar"

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
#warn() {
#	echo -e "${YELLOW}W:" "$@" "$BACK" >&2
#}

##############################################################################
#error() {
#	echo -e "${RED}E:" "$@" "$BACK" >&2
#	verbose exit 1
#}

##############################################################################
# Get latest Debian iso file (since the name changes)
get_debian_iso_url() {
	local NAME URL ISOCD="https://cdimage.debian.org/debian-cd/current/$DEBIANARCH/iso-dvd"
	NAME="$(wget -q -O- "$ISOCD" | sed -E '/debian-[0-9.]+-'"$DEBIANARCH"'-DVD-1.iso/!d; s/^.*href="//; s/".*$//;')"
	echo "$ISOCD/$NAME"
}

##############################################################################
default_config() {
	unset LC_TERMINAL
	unset LC_CTYPE
	LANG=C

	DEBIANARCH="amd64"
	DEBIANISO="$(get_debian_iso_url)"
	#DEBIANQCOW="https://cloud.debian.org/images/cloud/bullseye/latest/debian-$DEBIANVER-genericcloud-$DEBIANARCH.qcow2"
	FCVER=37
	FCREL="$FCVER-1.7"
	FCARCH="x86_64"
	FCDOWNLOAD="https://download.fedoraproject.org/pub/fedora/linux/releases/$FCVER"
	FCDESKTOP="$FCDOWNLOAD/Workstation/$FCARCH/iso/Fedora-Workstation-Live-$FCARCH-$FCREL.iso"
	FCSERVER="$FCDOWNLOAD/Server/$FCARCH/iso/Fedora-Server-dvd-$FCARCH-$FCREL.iso"
	#FCQCOW="$FCDOWNLOAD/Server/$FCARCH/images/Fedora-Server-KVM-$FCREL.$FCARCH.qcow2"
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
#get_vm_image() {
#	local URL=${1:?} FILE=${1##*/}
#	banner "Get VM Image: $FILE"
#	local QCOW=/var/lib/vz/template/qcow
#	$MKDIR "$QCOW"
#	$WGET -O "$QCOW/$FILE" "$URL"
#}

##############################################################################
get_iso() {
	local URL=${1:?} FILE=${1##*/}
	banner "Get ISO: $FILE"
	local ISO="/var/lib/vz/template/iso"
	$MKDIR "$ISO"
	$WGET -O "$ISO/$FILE" "$URL"
}

##############################################################################
get_vm_images() {
	#banner "Get ISO files"

	#get_vm_image "$DEBIANQCOW"
	get_iso "$DEBIANISO"
	#get_vm_image "$FCQCOW"
	get_iso "$FCDESKTOP"
	get_iso "$FCSERVER"
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
	case "$1" in
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
get_vm_images
banner "Finished downloading ISOs"
