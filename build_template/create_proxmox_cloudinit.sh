#!/bin/bash

usage() {
	CMDBASE=$(basename $0)
	echo "$CMDBASE creates a cloud-init that can be used with proxmox for root password"
	echo ""
	echo "Usage: $CMDBASE [options] <vm id>  <root pw>"
	echo "      --help                     print this help message"

	exit
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--help) usage ;;
		*) break ;;
	esac
	shift
done

if [[ $# -lt 2 ]]; then
	usage
fi

vm_id=$1
root_pw=$2

qm set $vm_id --scsi1 local:cloudinit
qm set $vm_id --ciuser root
qm set $vm_id --cipassword "$root_pw"
