#!/bin/bash
##############################################################################
# Written by: Behan Webster
# Licensed under the GPLv2
#
# Install templates for proxmox
#

set -e

VERSION=2.0

RED="\e[0;31m"
GREEN="\e[0;32m"
YELLOW="\e[0;33m"
#CYAN="\e[0;36m"
#BLUE="\e[0;34m"
BACK="\e[0m"

REINSTALL=
VERBOSE=

MKDIR="verbose mkdir -p"
PCT="verbose pct"
PVEAM="verbose pveam"
PVEUM="verbose pveum"
QM="verbose qm"
QMRESTORE="verbose qmrestore"
RM="verbose rm -f"
WGET="verbose wget --continue --quiet --show-progress --progress=bar"

CMUSERNAME="LFtraining"
CMPASSWORD="Penguin2014"

PIHOLE_VMID=100
DEBIAN_VMID=52000
DESKTOP_VMID=52010

PIHOLE_CONF="$HOME/tmp/pihole-config.tar.zst"
PIHOLE_IMG="/var/lib/vz/template/cache/pihole.tar.zst"
SERVER_IMG="$HOME/tmp/vzdump-qemu-52000.vma.zst"
DESKTOP_IMG="$HOME/tmp/vzdump-qemu-52010.vma.zst"

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
get_password() {
	PASSWD="$HOME/passwd.txt"
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
	DOMAIN="lf.training"
	USERID="student"
	PASSWORD="$(get_password)"
	NFS="/srv/LFT"
	DEBIANVER=11
	DEBIANARCH="amd64"
	LXCTEMPL="debian-$DEBIANVER-standard_$DEBIANVER.3-1_$DEBIANARCH.tar.zst"
}

##############################################################################
read_config() {
	default_config

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
install_packages() {
	banner "Install extra Debian packages"
	run_apt install needrestart
}

##############################################################################
setup_proxmox_users() {
	local USER="$USERID@pve" GROUP="admin"
	banner "Setup Proxmox users"
	set +e
	$PVEUM group add "$GROUP" -comment "System Administrators" 2>&1 | grep -v failed
	$PVEUM acl modify / -group "$GROUP" -role Administrator
	$PVEUM user del "$USER"
	$PVEUM user add "$USER" --password "$PASSWORD" --firstname "Linux" --lastname "Learner"
	$PVEUM user modify "$USER" -group admin
	$PVEUM pool add services --comment "Services Pool" 2>&1 | grep -v failed
	set -e
}

##############################################################################
setup_bridge() {
	local BRIDGE="vmbr0"
	local IFACE="eth0"
	local INTERFACES="/etc/network/interfaces"

	banner "Setup Bridge:$BRIDGE"
	if grep -q "iface $BRIDGE inet" "$INTERFACES" ; then
		warn "Network already configured: $BRIDGE"
	elif [[ -z $TEST ]] ; then
		info "Adding $BRIDGE to $INTERFACES"
		cat <<END >>"$INTERFACES"

auto $BRIDGE
iface $BRIDGE inet static
	address $NETWORK.1/$NETMASK
	bridge-ports none
	bridge-stp off
	bridge-fd 0
        post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
        post-up   iptables -t nat -A POSTROUTING -s '$NETWORK.0/$NETMASK' -o $IFACE -j MASQUERADE
	post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
        post-down iptables -t nat -D POSTROUTING -s '$NETWORK.0/$NETMASK' -o $IFACE -j MASQUERADE
	post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
END
	fi
	chmod 644 "$INTERFACES"

	info "Bring up $BRIDGE"
	verbose ifup $BRIDGE
}

##############################################################################
setup_firewall() {
	local FW="/etc/pve/firewall/cluster.fw"
	banner "Setup Cluster Firewall"
	if [[ -e "$FW" ]] ; then
		warn "Cluster Firewall already configured: $FW"
	elif [[ -z $TEST ]] ; then
		info "Install Cluster Firewall"
		$MKDIR "${FW%/*}"
		cat <<END >"$FW"
[OPTIONS]

enable: 1

[RULES]

GROUP ssh
GROUP proxmox -i eth0
GROUP web

[group proxmox] # Proxmox GUI

IN ACCEPT -p tcp -dport 8006 -log nolog # Proxmox web GUI
IN VNC(ACCEPT) -log nolog # VNC port
IN ACCEPT -p tcp -dport 3128 -log nolog # Spice Proxy for remote terminals

[group ssh] # Remote access

IN SSH(ACCEPT) -log nolog # SSH on normal port
IN ACCEPT -p udp -dport 60000:60010 -log nolog # Mosh access

[group web] # Web ports

IN HTTP(ACCEPT) -log nolog
IN HTTPS(ACCEPT) -log nolog

END
	fi
	chown -R root:www-data "${FW%/*}"

	local FW="/etc/pve/local/host.fw"
	banner "Setup Host Firewall"
	if [[ -e "$FW" ]] ; then
		warn "Host Firewall already configured: $FW"
	elif [[ -z $TEST ]] ; then
		info "Install Host Firewall"
		cat <<END >"$FW"
[RULES]

IN ACCEPT -i vmbr0 -p tcp -dport 111,2049 -log nolog # NFS
END
	fi

	chown -R root:www-data "${FW%/*}"

	if pve-firewall compile >/dev/null ; then
		info "Restart Firewall"
		verbose pve-firewall restart
	else
		error "Firewall rules failed"
	fi
}

##############################################################################
setup_network() {
	setup_bridge
	setup_firewall
}

##############################################################################
#update_dyndns() {
#	banner "Update DynDNS:"
#	# TODO
#}

##############################################################################
#update_letsencrypt() {
#	banner "Update Letsencrypt"
#	# TODO
#}

##############################################################################
#setup_dns() {
#	update_dyndns
#	update_letsencrypt
#}

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
	#local URL="http://training.linuxfoundation.org/cm/images"
	local URL="http://images.lf.training"

	banner "Get image $FILE"
	$MKDIR "$TEMPLDIR"
	$WGET --no-check-certificate --user="$CMUSERNAME" --password="$CMPASSWORD" -O "$TEMPLDIR/$FILE" "$URL/$FILE"
}

##############################################################################
lxc_already_installed() {
	local VMID=$1
	[[ -z ${REINSTALL} && -e "/etc/pve/lxc/$VMID.conf" ]] && pct list | grep -E -q -e "$VMID *running"
}

##############################################################################
restore_pihole() {
	local VMID="$PIHOLE_VMID" EXISTS=

	if lxc_already_installed "$VMID" ; then
		info "Pihole installed and running"
		return
	fi

	get_image "$PIHOLE_IMG"

	banner "Restore pihole"
	if [[ -e "/etc/pve/lxc/$VMID.conf" ]] ; then
		$PCT stop "$VMID"
		$PCT destroy "$VMID"
	fi
	$PCT create "$VMID" "$PIHOLE_IMG" --restore 1
		#--features "nesting=1" --hostname "pihole" --memory "1024" \
		#--net0 "name=eth0,bridge=vmbr0,gw=$NETWORK.1,ip=$NETWORK.2/$NETMASK" \
		#--onboot 1 --password "$PASSWORD" --unprivileged 0

	get_image "$PIHOLE_CONF"
	verbose tar -C /var/lib -x -f "$PIHOLE_CONF"
	$RM "$PIHOLE_CONF"

	$PCT start "$VMID"
}

##############################################################################
setup_containers() {
	get_lxc_templates
	restore_pihole
}

##############################################################################
vm_already_installed() {
	local VMID=$1
	[[ -z ${REINSTALL} && -e "/etc/pve/qemu-server/$VMID.conf" ]] && qm list | grep -E -q -e "$VMID .*stopped"
}

##############################################################################
install_vm_template() {
	local VMID=$1 IMAGE=$2 WHAT=$3
	if vm_already_installed "$VMID" ; then
		info "$WHAT template already installed"
		return
	fi

	banner "Get $WHAT Template"
	get_image "$IMAGE"
	banner "Restore $WHAT template"
	if [[ -e "/etc/pve/qemu-server/$VMID.conf" ]] ; then
		$QM destroy "$VMID"
	fi
	$QMRESTORE "$IMAGE" "$VMID" --unique 1
	$RM "$IMAGE"
}

##############################################################################
setup_vms() {
	install_vm_template "$DEBIAN_VMID" "$SERVER_IMG" "Debian Console"
	install_vm_template "$DESKTOP_VMID" "$DESKTOP_IMG" "Debian Desktop"
}

##############################################################################
download_images() {
	banner "Download templates"
	get_image "$PIHOLE_CONF"
	get_image "$PIHOLE_IMG"
	get_image "$SERVER_IMG"
	get_image "$DESKTOP_IMG"
}

##############################################################################
get_ip() {
	ip route get 1.1.1.1 | grep -oP 'src \K\S+'
}

##############################################################################
welcome() {
	local IP
	IP="$(get_ip)"

	banner "visit https://$IP:8006/ in your browser"
	info "Login as root, password $PASSWORD and Realm set to 'Linux PAM standard authentication'"
	#info "If your instructor can set $HOST.$DOMAIN to point to $IP you can then setup Letsencrypt"
}

##############################################################################
check_kernel_version() {
	local KVER
	KVER="$(uname -r | sed -E -e 's/^([0-9]+\.[0-9]+)\..*$/\1/')"

	if [[ $KVER != 5.15 ]] ; then
		warn "You need to reboot before continuing"
		info "Once you reboot, run install-templates.sh"
		exit 0
	fi
}

##############################################################################
do_the_thing() {
	check_kernel_version
	install_packages
	setup_proxmox_users
	setup_network
	#setup_dns
	setup_nfs
	setup_containers
	setup_vms
	welcome
}

##############################################################################
run_thing_in_byobu() {
	local DIR="${0%/*}"
	local GETKERN="${DIR:-.}/get-kernel.sh"
	local GETISOS="${DIR:-.}/get-isos.sh"

	if ! in_path byobu ; then
		run_apt update
		banner "Install byobu packages"
		run_apt install byobu
	fi
	if ! in_path byobu ; then
		error "byobu not found"
	fi

	if byobu list-session 2>&1 | grep -E -q -e "^no server|^error connecting" ; then
		byobu new-session -d -n 'install-templates' "$0 --run; bash"

		if [[ -f $GETISOS ]] ; then
			byobu new-window -t 1 -n 'get-isos' "$GETISOS"
		fi

		if [[ -f $GETKERN ]] ; then
			byobu new-window -t 2 -n 'get-kernel' "$GETKERN --download-only"
		fi

		byobu select-window -t 0
		byobu attach-session
	elif [[ -n $STY || -n $TMUX ]] ; then
		"$0" --run
	else
		byobu
	fi
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
		--run) RUN=y;;
		--list) sed -n '/^do_the_thing()/,/^\}$/{//!p;}' $0; exit 0;;
		--download-only) download_images; exit 0;;
		-n|--dry-run|--test) TEST="echo";;
		--reinstall) REINSTALL=y;;
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
elif [[ -n ${RUN:-} ]] ; then
	time do_the_thing
else
	run_thing_in_byobu
fi
