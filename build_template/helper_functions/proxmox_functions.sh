#!/bin/bash
##############################################################################
# Written by: John Bonesio
# Licensed under the GPLv2
#
# helper functions to manage proxmox VMs
#

proxmox_is_present() { echo "proxmox functions present"; }

# ###
# # vm_create <vmid> <options>
# #
# # 'vm_create' creates a vm with the given vmid and the provided hardware
# # options.
# #
# # The options the same as those give to the 'qm create' command
# #
# vm_create() {
# 	local vmid="$1" qm_create_opts="${@:2}"
# 
# 	qm create $vmid $qm_create_opts
# }

###
# vm_delete <vmid>
#
# 'vm_delete' deletes vm specified by the vmid.
#
vm_delete() {
	local vmid="$1"

	qm stop "$vmid"
	qm destroy "$vmid"
}

vm_is_template() {
	local vmid="$1" tmpl_line

	tmpl_line=$(qm config 52000 | grep template)

	if [[ -n $tmpl_line ]]; then
		echo "${tmpl_line##*: }"
		return
	fi
	echo ''
}

###
# pve_get_storage_name
#
# 'pve_get_storage_name' tries to grab the local storage name from
# proxmox.
#
# Currently this routine is not overly robust and assumes the output is in the
# correct form and only grabs the name from the last line in the list
#
pve_get_storage_name() {
	# example:
	# sudo pvesm status --enabled
	# Name         Type     Status           Total            Used       Available        %
	# local         dir     active       196133388        66599256       119538644   33.96%

	pvesm status --enabled | tail -1 | cut -d ' ' -f 1
}

###
# vm_start <vmid>
#
# 'vm_start' starts vm specified by the vmid.
#
vm_start() {
	local vmid="$1"

	qm start "$vmid"
}

###
# vm_status <vmid>
#
# 'vm_status' prints the status of the vm specified by the vmid.
#
# possible status: 'stopped', 'running', 'starting', 'stopping', 'pasued',
#                  'suspended'
#          or even 'missing' if there's no vm on <vmid> 
#
vm_status() {
	local vmid="$1" status_line

	status_line=$(sudo qm status "$vmid" 2>&1)

	if [[ "$status_line" =~ 'does not exist' ]]; then
		echo 'missing'
		return
	fi

	echo "${status_line##*: }"
}

###
# vm_mk_template <vmid>
#
# 'vm_mk_template' converts a vm into a template 
#
vm_mk_template() {
	local vmid="$1"

	qm template "$vmid"
}
