#!/bin/bash

#######
# Pull in helper functions
#

#source <(cat helper_functions/*.sh)

# source helper_functions/vm_image_functions.sh
source helper_functions/file_functions.sh
source helper_functions/proxmox_functions.sh
source helper_functions/msg_functions.sh
source helper_functions/str_functions.sh

set_lfd441_defaults() {
	#
	# if --name is not given
	#
	if [[ ! "$VM_OPTS" =~ --name ]]; then
		echo "filling in name from: $cloud_img"
		vm_name=$(basename "$cloud_img" .qcow2)
		VM_OPTS=$(str_append "$VM_OPTS" "--name $vm_name")
	fi
	VM_OPTS=$(str_append "$VM_OPTS" '--memory 2048 --cores 2 --bios ovmf --serial0 socket --net0 virtio,bridge=vmbr0,firewall=1,queues=2')
}

##
usage() {
	CMDBASE=$(basename $0)
	echo "$CMDBASE create a virtual machine in the proxmox enviornment"
	echo ""
	echo "Usage: $CMDBASE <vmid> [options] <cloud image qcow2 or raw> <cloud init iso file>"
	echo "      --storage <storage name>       If not specified try to detect"
	echo "      --keep-tmps                    don't delete temporary files (debugging)"
	echo "      --lfd441                       pick defaults for LFD441"
	echo "
	echo "      == qm create options ==
	echo "      To see full options, run: man qm.)"
	echo "      Also note: this script will automatically set up storage options for:"
	echo "        scsi0 for the main drive"
	echo "        ide0 for the cloud init .iso file"
	echo "        efidisk0 if bios ovmf is selected)"
	echo "     --name <vm name>"
	echo "     --machine <machine type>"
	echo "     --memory <ram in MB>"
	echo "     --cores <ncpus>"
	echo "     --net[n] ...             E.g.: --net0 virtio,bridge=vmbr0"
	echo "     --bios <ovmf | seabios>"
	echo "     --vga <display type>"

	exit
}

###
# Script starts here
###

### grab the options
args="$*" # incase we need to inspect again

vmid=$1
shift

pick_lfd441_defaults=''

VM_OPTS=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--scsihw) shift ;; # ignored for now, we set up or own drive parameters
		--scsi*) shift ;; # ignored for now, we set up or own drive parameters

		--storage) storage_name="$2" shift ;;
		--keep-tmps) file_keep_tmps ;;
		--lfd441) pick_lfd441_defaults='yes'  ;;
		--help) usage ;;

		# for any other options just collect them to be passed on to
		# 'qm create'
		--*) VM_OPTS=$(str_append "$VM_OPTS" "$1 ${2,,}"); shift ;;

		*) break ;;
	esac
	shift
done

cloud_img="$1"
cloud_init_iso="$2"

if [[ -n "$pick_lfd441_defaults" ]]; then
	set_lfd441_defaults
fi

#######
# Get the local storage name if not set
#######
if [[ -z "$storage_name" ]]; then
	storage_name="$(pve_get_storage_name)"
fi

uefi=""
if [[ "$VM_OPTS" =~ --bios\ *ovmf ]]; then
	uefi="true"
fi

echo "vmid: $vmid"
echo "storage_name: $storage_name"
echo "cloud_img: $cloud_img"
echo "cloud_init_iso: $cloud_init_iso"
echo "uefi: $uefi"
echo "options: [$VM_OPTS]"

if [[ -z "$vmid" || -z "$cloud_img" || -z "$cloud_init_iso" ]]; then
	usage
fi

###
# create the vm
# add the disks
# Connect the cloud image file to the vm
# Connect the cloud-init file to the vm
# set EFI disk if needed
# set boot order
info "creating vm $vmid, options: $VM_OPTS"
#qm create $vmid $qm_create_opts
qm create $vmid $VM_OPTS

info "importing disks: $cloud_img, $cloud_init_iso"
qm importdisk "$vmid" "$cloud_img" "$storage_name" --format qcow2
cp "$cloud_init_iso" "/var/lib/vz/template/iso/"

info "attaching main disk: vm-${vmid}-disk-0.qcow2 ($(basename $cloud_img))"
qm set "$vmid" --scsihw virtio-scsi-single --scsi0 "${storage_name}:${vmid}/vm-${vmid}-disk-0.qcow2,cache=writethrough,discard=on,iothread=1,ssd=1"

cloud_init_iso_base_name=$(basename "$cloud_init_iso")
info "attaching cloud-init: $cloud_init_iso_base_name"
qm set "$vmid" --ide2 "${storage_name}:iso/${cloud_init_iso_base_name},media=cdrom"

if [[ -n "$uefi" ]]; then
	info "setting up uefi"
	qm set "$vmid" --efidisk0 "${storage_name}:0,efitype=4m,format=qcow2,pre-enrolled-keys=1,size=528K"
fi

#
# The cloud-init settings don't work when using uefi bios unless ide2 is first
# in the boot order
#
info "setting boot order"
qm set "$vmid" --boot order='ide2;scsi0'
