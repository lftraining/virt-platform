#!/bin/bash

#######
# Pull in helper functions
#

#source <(cat helper_functions/*.sh)

#source helper_functions/vm_image_functions.sh
source helper_functions/file_functions.sh
source helper_functions/proxmox_functions.sh
source helper_functions/msg_functions.sh
source helper_functions/str_functions.sh

#######
# main variables
vm_id=""
vm_name=""
src_uri=""
storage_name=""
VM_OPTS=""
IMG_OPTS=""

# test option to quickly destroy the vm before proceeding
destroy_if_exists=''

###
print_opts() {
	while [[ $# -gt 0 ]]; do
		if [[ $# -eq 1 || ${2:0:2} == '--' ]]; then
			echo "  $1"
		elif [[ $# -eq 2 || ${3:0:2} == '--' ]]; then
			echo "  $1 $2"
			shift
		else
			echo "  $1 $2 $3"
			shift
			shift
		fi
		shift
	done
}

###
print_settings() {
	echo "Creating new template (name: $vm_name, id: $vm_id) from $src_uri "

	echo "Hardware options:"
	print_opts $VM_OPTS
	echo "  disk: ${vm_img_name}"
	echo "  cloud-init: ${cloud_init_name}"
	
	echo "Guest O/S options:"
	print_opts $IMG_OPTS
}

###
# LFD441 defaults
set_lfd441_defaults() {
	VM_OPTS=$(str_append "$VM_OPTS" "--memory 2048 --cores 2 --bios ovmf \
--serial0 socket --vga virtio")

	IMG_OPTS=$(str_append "$IMG_OPTS" "--user student --passwd \"I<3Penguins\" --sudoer nopwd \
--root-pw Penguin2014 --gnome auto-login --gnome screen-blank-off \
--tz \"America/Chicago\" --host 10.10.10.1 proxmox --host 10.10.10.2 pihole \
--serial-tty ttyS0 --size 32G")
}

##
usage() {
	CMDBASE=$(basename $0)
	echo "$CMDBASE creates a proxmox template from a qcow2 cloud image and grabs a vma.zst backup of it"
	echo ""
	echo "Usage: $CMDBASE <vm id> [options] <template name> <cloud image (url or filepath)>"
	echo "      --storage <storage name>   force storage name to use e.g. 'local'"
	echo "      --memory <sz in MB>        set ram size"
	echo "      --cores <n cpus>           set number of cpus"
	echo "      --bios <ovmf|seabios>      set bios type"

	echo "      --desktop                  install gnome desktop environment"
	echo "      --gnome auto-login|"
	echo "              screen-blank-off   Setting gnome desktop settings"
	echo "                                 multiple --gnome options possible"
	echo "      --user <user name>         specify the user account name"
	echo "      --passwd <user password>   specify the user account password"
	echo "      --sudoer nopwd|yes         user can use sudo with or w/o password"
	echo "      --root-passwd <root pw>    specify the root account password"
	echo "      --tz <timezone text>       specify the timezone"
	echo "      --host <ip> <hostname>     specify a hostname for /etc/hosts"
	echo "                                 multiple --host options possible"
	echo "      --nfs <server> <mount>     add an nfs share to auto mount"
	echo "                                 multiple --nfs options possible"
	echo "      --serial-tty <serial dev>  add tty (without /dev/) on serial port"
	echo "      --size <new img size>      specify size e.g. 32G"
	echo "      --keep-tmps                don't delete temporary files and directories"
	echo "      --lfd441                   defaults for hardware and the image for LFD441"
	echo "      --help                     print this help message"

	exit
}

###
# Script starts here
###
args="$*"

vm_id="$1"
shift

pick_lfd441_defaults=''

serial_cnt=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		--storage) storage_name="$2" shift ;;

		--memory|--cores|--bios|--vga)
			if [[ $2 =~ ^'--' ]]; then error "option $1 requires a parameter"; fi
			VM_OPTS=$(str_append "$VM_OPTS" "$1 $2")
			shift ;;
		--scsihw|--scsi*|--net*)
			# ignored for now, we set up or own drive parameters
			if [[ $2 =~ ^'--' ]]; then error "option $1 requires a parameter"; fi
			shift ;;
		--desktop)
			IMG_OPTS=$(str_append "$IMG_OPTS" "$1 auto")
			if [[ ${2:0:2} != '--' ]]; then  shift; fi
			;;
		--gnome|--user|--passw*|--sudoer|--root-p*|--tz|--size)
			if [[ $2 =~ ^'--' ]]; then error "option $1 requires a parameter"; fi
			IMG_OPTS=$(str_append "$IMG_OPTS" "$1 $2")
			shift ;;
		--host|--nfs)
			if [[ $2 =~ ^'--'  || $3 =~ ^'--'  ]]; then
				error "option $1 requires two parameters"
			fi
			IMG_OPTS=$(str_append "$IMG_OPTS" "$1 $2 $3")
			shift; shift ;;
		--serial-tty)
			if [[ $2 =~ ^'--' ]]; then error "option $1 requires a parameter"; fi
			VM_OPTS=$(str_append "$VM_OPTS" "--serial${serial_cnt} socket")
			IMG_OPTS=$(str_append "$IMG_OPTS" "--serial-tty $2")
			(( serial_cnt++ ))
			shift; ;;
		--keep-tmps)
			VM_OPTS=$(str_append "$VM_OPTS" $1)
			IMG_OPTS=$(str_append "$IMG_OPTS" $1)
			file_keep_tmps ;;
		--destroy) destroy_if_exists='yes' ;;
		--lfd441) pick_lfd441_defaults='yes'  ;;
		--help) usage ;;
		--*) echo "unknown option $1"; usage ;;
		*) break ;;
	esac
	shift
done

vm_name="$1"
src_uri="$2"
vm_img_name="${vm_name}.qcow2"
cloud_init_name="cloudinit-${vm_name}.iso"

if [[ -z "$vm_id" || -z "$vm_name" || -z "$src_uri" ]]; then
	usage
fi

if [[ -n "$pick_lfd441_defaults" ]]; then
	set_lfd441_defaults
fi

#######
# Check if vm_id exists
#######
if [[ $(vm_status $vm_id) != 'missing' ]]; then
	if [[ "$destroy_if_exists" != "yes" ]]; then
		error "VM on id $vm_id already exists"
	fi
	vm_delete $vm_id
fi

#######
# Get the local storage name if not set
#######
if [[ -z "$storage_name" ]]; then
	storage_name="$(pve_get_storage_name)"
fi

VM_OPTS="$VM_OPTS --net0 virtio,bridge=vmbr0,firewall=1,queues=2 --storage $storage_name"

print_settings

#######
# download/copy the qcow2 image, prepare the image and create a
# cloud-init.iso file
#######
info "generating qcow2 and iso files"

disp_n_call ./mk_cloud_img_init.sh $IMG_OPTS $src_uri "$vm_img_name"

#######
# make the proxmox vm with the prepared qcow2 iamge and cloud-init.iso file
#######

#
# invoke create_vm.sh to make the vm for us
#
info "creating proxmox vm"
disp_n_call ./create_vm.sh $vm_id --name "$vm_name" $VM_OPTS "$vm_img_name" "$cloud_init_name"

#######
# Run the vm and wait for the operator to install the desktop if needed
# This also lets the cloud-init.iso settings take hold
#######
echo "#######"
echo "# The VM is now staring. Please login to make sure clout-init is"
echo "# complete before we proceed."
echo "# If needed, you can wait with the command:"
echo "#    cloud-init status --wait"
echo "# Shutdown the guest when ready to proceed."
echo "#######"
info "starting vm"
qm start "$vm_id"

echo "waiting for VM $vm_id to be stopped"
spinner_start
while [[ "$(vm_status "$vm_id")" != 'stopped' ]]; do
	spinner_print_next
done

sleep "1" # give time for things to settle down

#######
# Now our custom cloud-init is done, set up another one so the root pw can be
# changed in proxmox if forgotten
#######
info "setting new cloud-init for use in proxmox"
_root_pw=$(echo "$IMG_OPTS" | sed 's/.*--root-p[^ ]* \([^ ]*\).*/\1/')
if [[ -z "$_root_pw" ]]; then
	_root_pw="qwerty"
fi
disp_n_call ./create_proxmox_cloudinit.sh "$vm_id" "$_root_pw"

#######
# Convert the vm to a template compressing the qcow2 image in the process
#######
info "compressing and converting vm to a template"
disp_n_call ./convert_to_template.sh "$vm_id"

sleep "1" # give time for things to settle down
#######
# Create a backup of the template and copy it out to the current directory
#######
info "creating a backup of the template to the current directory"
disp_n_call ./backup_to.sh "$vm_id" '.'

backup_file=$(file_find_newest "./vzdump-qemu-${vm_id}*.vma.zst")
if [[ -f "$backup_file" ]]; then
	echo "#######"
	echo "You can now copy $backup_file to the cm server path: cm/images"
	echo "#######"
else
	echo "#######"
	echo "Something went wrong. vzdump-qemu-${vm_id}*.vma.zst not found"
	echo "#######"
fi
