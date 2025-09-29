#!/bin/bash
##############################################################################
# Written by: John Bonesio
# Licensed under the GPLv2
#
# Backup a Proxmox template and copy it out
#

source helper_functions/proxmox_functions.sh
source helper_functions/file_functions.sh
source helper_functions/msg_functions.sh

##
usage() {
	CMDBASE=$(basename $0)
	echo "$CMDBASE make a backup of the template to the specified directory"
	echo ""
	echo "Usage: $CMDBASE <vmid> {target name (current directory if omitted)}"
}

vmid="$1"
target="${2:-.}"

if [[ -z $(vm_is_template $vmid) ]];then
	error "vm $vmid is not a template, make it a template first."
fi

vzdump "$vmid" --compress zstd --notification-mode notification-system
backup_file=$(file_find_newest "/var/lib/vz/dump/vzdump-qemu-${vmid}*.vma.zst")
rsync -ah --progress "$backup_file" "$target"
