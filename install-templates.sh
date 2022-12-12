#!/bin/bash
##############################################################################
# Written by: Behan Webster
# Licensed under the GPLv2
#
# Install templates for proxmox
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
PCT="verbose pct"
PVEAM="verbose pveam"
QM="verbose qm"
QMRESTORE="verbose qmrestore"
RM="verbose rm -f"
WGET="verbose wget --continue --quiet --show-progress --progress=bar"

CMUSERNAME="LFtraining"
CMPASSWORD="Penguin2014"

PIHOLE_VMID=100
DEBIAN_VMID=52000
DESKTOP_VMID=52010
SOURCESD="/etc/apt/sources.list.d"
ENTERPRISE="$SOURCESD/pve-enterprise.list"

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

##############################################################################
generate_password() {
	< /dev/urandom tr -dc _A-Z-a-z-0-9 | head "-c${1:-16}";echo; 
}

##############################################################################
get_password() {
	PASSWD="$HOME/passwd.txt"
	if [[ ! -e $PASSWD ]] ; then
		generate_password 16 >"$PASSWD"
	fi
	cat "$PASSWD"
}

##############################################################################
default_config() {
	unset LC_TERMINAL
	unset LC_CTYPE
	LANG=C

	TEST="${TEST:+echo}"
	NETWORK="10.10.10"
	NETMASK="24"
	PASSWORD="$(get_password)"
	NFS="/srv/LFT"
	DEBIANVER=11
	DEBIANARCH="amd64"
	LXCTEMPL="debian-$DEBIANVER-standard_$DEBIANVER.3-1_$DEBIANARCH.tar.zst"
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
	$RM "$ENTERPRISE"
	run_apt update
	run_apt full-upgrade
}

##############################################################################
install_debian_extras() {
	if dpkg --get-selections postfix | grep -q install ; then
		warn "Postfix already installed"
	else
		banner "Install Postfix"
		verbose debconf-set-selections <<< "postfix postfix/mailname string $HOSTNAME"
		verbose debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Local only'"
		run_apt install postfix
		$RM debconf-set-selections
	fi

	banner "Install extra Debian packages"
	run_apt install chrony etckeeper ksmtuned lsof mosh needrestart nfs-kernel-server rsync ssh sudo unattended-upgrades

	banner "Remove uneeded Debian packages"
	run_apt purge reportbug python3-debian python3-debianbts python3-httplib2 python3-pycurl python3-pysimplesoap python3-reportbug
}

##############################################################################
setup_debian() {
	update_debian
	install_debian_extras
}

##############################################################################
check_kernel_version() {
	local KVER
	KVER="$(uname -r | sed -E -e 's/^([0-9]+\.[0-9]+)\..*$/\1/')"

	if [[ $KVER != 5.15 ]] ; then
		warn "You need to reboot before continuing"
		info "Once you reboot, rerun $0"
		exit 0
	fi
}

##############################################################################
setup_nfs() {
	local EXPORTS="/etc/exports"
	banner "Setup NFS"
	if grep -q "^$NFS" "$EXPORTS" ; then
		warn "NFS Export already added."
	elif [[ -z $TEST ]] ; then
		cat <<END >>"$EXPORTS"
$NFS	$NETWORK.0/$NETMASK(rw,sync,no_subtree_check)
END
	fi

	info "Exportfs NFS"
	$MKDIR "$NFS"
	verbose chmod 2777 "$NFS"
	verbose exportfs -a
	verbose showmount -e
}

##############################################################################
get_lxc_templates() {
	LXCTEMPL="$(pveam available | awk "/${LXCTEMPL%%_*}/ {print \$2}" | tail -1)"
	banner "Download $LXCTEMPL"
	$PVEAM update
	$PVEAM download local "$LXCTEMPL"
}

##############################################################################
#create_lxc() {
#	local ID=$1 NAME=$2 IMAGE=$3 PASSWD=$4
#	banner "Create container for $ID/$NAME"
#	$PCT create "$ID" "local:vztmpl/$IMAGE" \
#		--hostname "$NAME" \
#		--net0 name=eth0,bridge=vmbr0,ip="$NETWORK.2/$NETMASK,gw=$NETWORK.1" \
#		--onboot 1 \
#		--ostype debian \
#		--password "$PASSWORD" \
#		--unprivileged 0
#	#verbose set "$ID" -onboot 1
#}

##############################################################################
get_image() {
	local FILE=${1##*/}
	local TEMPLDIR=${1%/*}
	local URL="http://training.linuxfoundation.org/cm/images"

	banner "Get image $FILE"
	$MKDIR "$TEMPLDIR"
	$WGET --no-check-certificate --user="$CMUSERNAME" --password="$CMPASSWORD" -O "$TEMPLDIR/$FILE" "$URL/$FILE"
}

##############################################################################
restore_pihole() {
	local VMID="$PIHOLE_VMID"
	local IMAGE="/var/lib/vz/template/cache/pihole.tar.zst"
	local CONFIG="/tmp/pihole-config.tar.zst"

	get_image "$IMAGE"

	banner "Restore pihole"
	if [[ -e "/etc/pve/lxc/$VMID.conf" ]] ; then
		$PCT destroy "$VMID"
	fi
	$PCT create "$VMID" "$IMAGE" --restore 1
		#--features "nesting=1" --hostname "pihole" --memory "1024" \
		#--net0 "name=eth0,bridge=vmbr0,gw=$NETWORK.1,ip=$NETWORK.2/$NETMASK" \
		#--onboot 1 --password "$PASSWORD" --unprivileged 0

	get_image "$CONFIG"
	verbose tar -C /var/lib -x -f "$CONFIG"

	$PCT start "$VMID"
}

##############################################################################
setup_containers() {
	get_lxc_templates
	restore_pihole
}

##############################################################################
install_debian_console_template() {
	banner "Get Debian Console Template"
	local IMAGE="/tmp/vzdump-qemu-52000.vma.zst"
	get_image "$IMAGE"
	banner "Restore debian template"
	if [[ -e "/etc/pve/qemu-server/$DEBIAN_VMID.conf" ]] ; then
		$QM destroy "$DEBIAN_VMID"
	fi
	$QMRESTORE "$IMAGE" "$DEBIAN_VMID" --unique 1
	#$QM set "$DEBIAN_VMID" --template 1
	$RM "$IMAGE"
}

##############################################################################
install_debian_desktop_template() {
	banner "Get Debian Desktop Template"
	local IMAGE="/tmp/vzdump-qemu-52010.vma.zst"
	get_image "$IMAGE"
	banner "Restore debian desktop template"
	if [[ -e "/etc/pve/qemu-server/$DESKTOP_VMID.conf" ]] ; then
		$QM destroy "$DESKTOP_VMID"
	fi
	$QMRESTORE "$IMAGE" "$DESKTOP_VMID" --unique 1
	#$QM set "$DESKTOP_VMID" --template 1
	$RM "$IMAGE"
}

##############################################################################
setup_vms() {
	install_debian_console_template
	install_debian_desktop_template
}

##############################################################################
do_the_thing() {
	check_kernel_version
	setup_nfs
	setup_containers
	setup_vms
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
