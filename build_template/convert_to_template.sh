#!/bin/bash
##############################################################################
# Written by: John Bonesio
# Licensed under the GPLv2
#
# Shrink the file size of a Proxmox VM and then make it a template
#
# The shrinking is done through virt-sparsify which makes writes 0's to all the
# unused blocks and making the file sparse.
#

#######
# Pull in helper functions
#

source helper_functions/proxmox_functions.sh

##
usage() {
	CMDBASE=$(basename $0)
	echo "$CMDBASE shrink vm space used and convert vm to a template"
	echo ""
	echo "Usage: $CMDBASE <vmid>"
}

###
# Script starts here
###

### grab the options
#while [[ $# -gt 0 ]]; do
#	case "$1" in
#		--storage) storage_name="$2" shift ;;
#	esac
#	shift
#done

vmid="$1"


###
# make sure the vm is stopped
# run sparsify on the vm's qcow2 
# make the vm a template (there's qm command for this)
if [[ "$(vm_status $vmid)" != 'stopped' ]]; then
	echo "vm $vmid is not stopped. Please stop it first"
	exit
fi

if [[ -f "/var/lib/vz/images/${vmid}/tmp.qcow2" ]]; then
	sudo rm "/var/lib/vz/images/${vmid}/tmp.qcow2"
fi

if [[ ! -d 'tmp_dir' ]]; then mkdir tmp_dir; fi
#sudo virt-sparsify -check-tmpdir=ignore --quiet --compress "/var/lib/vz/images/${vmid}/vm-${vmid}-disk-0.qcow2" "/var/lib/vz/images/${vmid}/tmp.qcow2"
sudo virt-sparsify --tmp tmp_dir --compress "/var/lib/vz/images/${vmid}/vm-${vmid}-disk-0.qcow2" "/var/lib/vz/images/${vmid}/tmp.qcow2"
if [[ ! -f "/var/lib/vz/images/${vmid}/tmp.qcow2" ]]; then
	echo "shrinking the disk image didn't work"
	exit
fi

if [[ -f "/var/lib/vz/images/${vmid}/tmp.qcow2" ]]; then
	sudo mv "/var/lib/vz/images/${vmid}/tmp.qcow2" "/var/lib/vz/images/${vmid}/vm-${vmid}-disk-0.qcow2" 
else
	error "shrinking the vm appears to not have worked"
fi

qm template "$vmid"

