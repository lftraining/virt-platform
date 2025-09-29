#!/bin/bash
##############################################################################
# Written by: Behan Webster
# Licensed under the GPLv2
#
# Create an image template on a Proxmox host machine.
#
# Source:
#   https://www.yanboyang.com/clouldinit/
#   https://gist.github.com/chriswayg/43fbea910e024cbe608d7dcb12cb8466
#   https://github.com/modem7/public_scripts/blob/master/Bash/Proxmox%20Scripts/create-jammy-cloud-template.sh

set -u
set -e

VERSION=1.1

TEST="${TEST:+echo}"

# Prerequesites:
#   - Install "apt-get install libguestfs-tools".

RED="\e[0;31m"
GREEN="\e[0;32m"
#YELLOW="\e[0;33m"
#CYAN="\e[0;36m"
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
verbose() {
	echo "+" "$@" >&2
	if [[ -z ${TEST:-} ]] ; then
		"$@"
	fi
}

################################################################################
# Check if libguestfs-tools is installed - exit if it isn't.
check_libguestfs() {
	local REQUIRED_PKG="libguestfs-tools" PKG_OK
	PKG_OK=$(dpkg-query -W --showformat='${Status}\n' $REQUIRED_PKG | grep "install ok installed")
	echo "Checking for $REQUIRED_PKG: $PKG_OK"
	if [[ -z $PKG_OK ]] ; then
  		error "No $REQUIRED_PKG. Please run apt-get install $REQUIRED_PKG."
	fi
}
check_libguestfs

################################################################################
exit_handler() {
	if [[ -z ${KEEPWORK:-} && -n ${RMDIR:-} && -n ${WORKDIR:-} ]] ; then
		rm -rf "$WORKDIR"
	fi
}
trap exit_handler EXIT ERR

WORKDIR=/tmp/proxmox
################################################################################
# Build a working directory
if [[ -z ${WORKDIR:-} ]] ; then
	WORKDIR="$(mktemp -d /tmp/proxmox-template-$(date +%s)-XXXXXX)"
elif [[ ! -d $WORKDIR ]] ; then
	mkdir -p "$WORKDIR"
fi

################################################################################
in_path() {
	command -v "$@" >/dev/null 2>&1
}

declare -A META

################################################################################
# Download image
download_image() {
	local URL=${1:?} IMAGE
	IMAGE="${URL##*/}"; IMAGE="$WORKDIR/${IMAGE/.img/.qcow2}"
	info "Downloading $IMAGE from $URL"
	if true ; then
		(cd "$HOME"; verbose wget -c -q --show-progress -N "$URL")
		cp -v "$HOME/${IMAGE##*/}" "$IMAGE" >&2
	else
		verbose wget -c -q --show-progress -N "$URL" -O "$IMAGE"
	fi

	echo "$IMAGE"
}

################################################################################
set_timezone() {
	local IMAGE=${1:?}

	if in_path timedatectl ; then
		# shellcheck disable=SC1090
		. <(timedatectl show | sed -E 's/=(.*)$/="\1"/')
	else
		Timezone="$(cat /etc/timezone)"
	fi

	if [[ -n "${Timezone+set}" ]] ; then
		info "Setting up TZ on $IMAGE"
		verbose virt-customize -a "$IMAGE" --timezone "$Timezone"
	fi
}

################################################################################
enable_x11() {
	local IMAGE=${1:?}
	local LOCALLANG="en_US.UTF-8"
	local X11LAYOUT="us"
	local X11MODEL="pc104"

	info "Setting up keyboard language and locale on $IMAGE"
	verbose virt-customize -a "$IMAGE" \
		--firstboot-command "localectl set-locale LANG=$LOCALLANG" \
		--firstboot-command "localectl set-x11-keymap $X11LAYOUT $X11MODEL"
}

################################################################################
# install qemu-guest-agent inside image
install_packages() {
	local IMAGE=${1:?}
	info "Updating system and Installing packages on $IMAGE"

	if [[ -n ${META[EXPAND]+set} ]] ; then
		mv "$IMAGE" "$IMAGE-orig"
		verbose qemu-img resize "$IMAGE-orig" "${META[EXPAND]}"
		#verbose virt-resize --resize "/dev/sda1=${META[EXPAND]}" "$IMAGE-orig" "$IMAGE"
		#rm -f "$IMAGE-orig"
	fi
	verbose virt-customize -a "$IMAGE" --update --install "${META[VIRTPKGS]}"
}

################################################################################
add_cloud_init_to_image() {
	local IMAGE=${1:?} CFG="$WORKDIR/99_pve.cfg"

	info "Creating Proxmox Cloud-init config $IMAGE"
	cat >"$CFG" <<EOF
# to update this file, run dpkg-reconfigure cloud-init
datasource_list: [ NoCloud, ConfigDrive ]
EOF

	info "Copying Proxmox Cloud-init config to $IMAGE"
	verbose virt-customize -a "$IMAGE" --upload "$CFG:/etc/cloud/cloud.cfg.d/"

	rm -f "$CFG"
}

################################################################################
customize_image() {
	local VMID=${1:?} LFT
	info "Add further customizations to $VMID"

	SERVER="10.10.10.1"
	LFT="/srv/LFT"
	verbose virt-customize -a "$IMAGE" \
		--mkdir "$LFT" \
		--append-line "/etc/fstab:$SERVER:$LFT $LFT nfs soft 0 0"
}

################################################################################
check_network() {
	local BRIDGE=${1:?}
	in_path ip || "Run this script on a Proxmox host"
	ip addr show "$BRIDGE" &>/dev/null || error "Network bridge $BRIDGE not found on this server"
}

################################################################################
check_storage() {
	local STORAGE=${1:?}
	in_path pvesm || "Run this script on a Proxmox host"
	pvesm status | grep -q "$STORAGE" || error "Storage $STORAGE not found on this server"
}

################################################################################
# create VM
create_vm() {
	local VMID=${1:?} IMAGE=${2:?} TEMPLATE=${3:-}
	if [[ -z $TEMPLATE ]] ; then
		TEMPLATE="${IMAGE##*/}"; TEMPLATE="${TEMPLATE%.qcow2}"
	fi
	info "Create Proxmox VM $VMID as $TEMPLATE"

	check_network "${META[BRIDGE]}"
	check_storage "${META[STORAGE]}"
	verbose qm create "$VMID" --name "$TEMPLATE" --bios "${META[BIOS]}" --vga "${META[VGA]}" \
		--cores "${META[CPUS]}" --memory "${META[MEM]}" --balloon "${META[BALLOON]}" \
		--net0 "virtio,bridge=${META[BRIDGE]}${META[VLAN]:+,tag=${META[VLAN]}}"
	#verbose qm set "$VMID" --agent enabled=1,fstrim_cloned_disks=1
	verbose qm set "$VMID" --serial0 socket
	verbose qm set "$VMID" --ipconfig0 ip=dhcp
	verbose qm set "$VMID" --ostype "${META[OS_TYPE]}"
	verbose qm set "$VMID" --hotplug "disk,network,usb"
	verbose qm set "$VMID" --rng0 source=/dev/urandom
	verbose qm set "$VMID" --description "Proxmox $TEMPLATE template"
}

################################################################################
# Add storage
add_storage() {
	local VMID=${1:?} IMAGE=${2:?}
	info "Add Storage to $VMID from $IMAGE"

	verbose qm importdisk "$VMID" "$IMAGE" "${META[STORAGE]}" -format qcow2
	verbose qm set "$VMID" --scsihw virtio-scsi-single --scsi0 "${META[STORAGE]}:$VMID/vm-$VMID-disk-0.qcow2,cache=writethrough,discard=on,iothread=1,ssd=1"
	verbose qm set "$VMID" --scsi1 "${META[STORAGE]}:cloudinit"
	verbose qm set "$VMID" --efidisk0 "${META[STORAGE]}:0,efitype=4m,format=qcow2,pre-enrolled-keys=1,size=528K"
	#verbose qm set "$VMID" --tpmstate0 "${META[STORAGE]}:0,size=4M,version=v2.0"
	verbose qm set "$VMID" --boot c --bootdisk scsi0
	verbose qm resize "$VMID" scsi0 "${META[DISK]}"
}

################################################################################
# create VM
fill_cloud_init() {
	local VMID=${1:?}
	info "Configure Cloud-init on $VMID"

	verbose qm set "$VMID" --ciuser "${META[CLOUD_USER]}"
	verbose qm set "$VMID" --cipassword "${META[CLOUD_PASSWORD]}"

	if [[ -n ${META[SSHKEY]+set} ]] ; then
		if [[ -f ${META[SSHKEY]} ]] ; then
			verbose qm set "$VMID" --sshkey "${META[SSHKEY]}"
		else
			PUBKEY="$(mktemp "$WORKDIR/sshkey.XXX.pub")"
			echo "${META[SSHKEY]}" >"$PUBKEY"
			verbose qm set "$VMID" --sshkey "$PUBKEY"
			rm -f "$PUBKEY"
		fi
	fi
}

################################################################################
cleanup() {
	local IMAGE=${1:?}

	verbose virt-customize -a "$IMAGE" \
		--run-command "apt -y autoremove --purge" \
		--run-command "apt -y clean" \
		--run-command "apt -y autoclean" \
		--run-command "cloud-init clean" \
		--run-command "fstrim -a" \
		--truncate /etc/machine-id
}

################################################################################
add_a_user() {
	local IMAGE=${1:?} ACCT=${2:-}
	[[ -n $ACCT ]] || return 0
	verbose virt-customize -a "$IMAGE" \
		--run-command "useradd --create-home ${ACCT%%:*}" \
		--run-command "echo '$ACCT' | chpasswd"
}

################################################################################
create_template() {
	local IMAGE VMID ACCT=${1:-}

	VMID="${META[VMID]}"

	IMAGE="$(download_image "${META[SRC_URL]}")"
	set_timezone "$IMAGE"
	enable_x11 "$IMAGE"
	install_packages "$IMAGE"
	add_cloud_init_to_image "$IMAGE"
	cleanup "$IMAGE"
	add_a_user "$IMAGE" "$ACCT"
	create_vm "$VMID" "$IMAGE" "${META[TEMPLATE]}"
	add_storage "$VMID" "$IMAGE"
	fill_cloud_init "$VMID"

	verbose qm set "$VMID" --template 1
	info "VM Created as $VMID"
}

################################################################################
# Image variables
#META[SRC_URL]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"

#META[SRC_URL]="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2"
META[SRC_URL]="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2"
META[TEMPLATE]="debian-cli"
META[VMID]="52000"
META[OS_TYPE]="l26"
META[CPUS]="2"
META[MEM]="2048"
META[BALLOON]="512"
META[BIOS]="ovmf"
#META[BIOS]="seabios"
#META[VGA]="std"
META[VGA]="virtio"
#META[VGA]="vmware"
META[DISK]="8G"
META[STORAGE]="local"
META[BRIDGE]="vmbr0"
META[VLAN]=
META[VIRTPKGS]="qemu-guest-agent,cloud-utils,nfs-common,rsync,sudo"

META[CLOUD_USER]="root"
META[CLOUD_PASSWORD]="I<3Penguins"
#META[SSHKEY]="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOFLnUCnFyoONBwVMs1Gj4EqERx+Pc81dyhF6IuF26WM proxvms"
META[SSHKEY]="$HOME/.ssh/id_ed25519.pub"

################################################################################
#create_template

#META[SRC_URL]="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-nocloud-amd64.qcow2"
META[TEMPLATE]="debian-desktop"
META[VMID]="52011"
META[MEM]="4096"
#META[EXPAND]="16G"
META[DISK]="16G"
#META[VIRTPKGS]+=",task-gnome-desktop,xserver-xorg-video-qxl,firefox-esr"
#META[VIRTPKGS]+=",stable/gnome"
create_template "student:${META[CLOUD_PASSWORD]}"
