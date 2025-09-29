#!/bin/bash
##############################################################################
# Written by: John Bonesio
# Licensed under the GPLv2
#
# helper functions to operate on VM images (qcow2 files)
#

vm_is_present() { echo "vm functions present"; }

###
# img_find_distro_type <img_file>
#
# 'img_find_distro_type' attempts to determine the distibution inside a qemu image file.
#
# If the distribution is found 'img_find_distro_type' prints the distribution name.
# Otherwise, 'img_find_distro_type' prints the empty string.
#
img_find_distro_type() {
	local img_file="$1"

	virt-cat -a "$img_file" /etc/os-release | grep '^ID=' | sed s/ID=//g
}

###
# img_find_distro_version <img_file>
#
# 'img_find_distro_version' attempts to determine the version of the distibution
# inside a qemu image file.
#
# If the distribution version is found 'img_find_distro_version' prints the
# distribution name. Otherwise, 'img_find_distro_version' prints the empty string.
#
img_find_distro_version() {
	local img_file="$1" ver

	virt-cat -a "$img_file" /etc/os-release | grep '^VERSION_ID=' | sed s/VERSION_ID=//g
}

###
# img_is_qemu_image <img_file>
#
# 'img_is_qemu_image' checks if a qcow2 or raw disk image file based solely on
# the file name extention.
#
# if the file is a qemu image file, 'img_is_qemu_image' prints 'qemu'.
# Otherwise, 'img_is_qemu_image' prints the empty string.
#
img_is_qemu_image() {
	local img_file="$1" ext

	ext="${img_file##*.}"

	if [[ "$ext" != "qcow2" && "$ext" != "img" && "$ext" != "raw" ]]; then
		echo ""
		return
	fi
	echo "qemu"
}

###
# img_is_cloud_image <img_file>
#
# 'img_is_cloud_image' checks if a qcow2 or raw disk image file is setup to
# use cloud-init settings.
#
# if the image file contains cloud-init settings, 'img_is_cloud_image' prints
# 'cloud'. Otherwise, 'img_is_cloud_image' prints the empty string.
#
img_is_cloud_image() {
	local img_file="$1"

	if [[ "$(img_is_qemu_image $img_file)" != "qemu" ]]; then
		echo ""
		return
	fi

	found_cloud=$(virt-ls -a "$img_file" /etc/ | grep cloud 2>&1)

	if [[ "$found_cloud" == '' || "$found_cloud" =~ 'No such file' ]]; then
		found_cloud=$(virt-ls -a "$img_file" /var/ | grep cloud 2>&1)
	fi
	if [[ "$found_cloud" == '' || "$found_cloud" =~ 'No such file' ]]; then
		found_cloud=""
	else
		found_cloud="cloud"
	fi

	echo "$found_cloud"
}

###
# img_get_hosts_file <img_file> [distro]
#
# 'img_get_hosts_file' prints the path to the hosts file. On normal systems,
# this is /etc/hosts. But in cloud images this is often a file in
# /etc/cloud/templates/hosts.*.tmpl
#
# if 'distro' is not provied 'img_get_hosts_file' will attempt to retrieve the
# distro name from the image.
#
img_get_hosts_file() {
	local img_file="$1" distro="$2" templ_dir

	if [[ -z "$distro" ]]; then
		distro=$(img_find_distro_type "$img_file")
	fi

	if [[ "$distro" == "fedora" ]]; then
		distro=redhat
	fi

	templ_dir=$(virt-ls -a "$img_file" "/etc/cloud/templates/" 2>&1)

	if [[ "$templ_dir" =~ 'No such file' ]]; then
		echo '/etc/hosts'
		return
	fi 

	if [[ "$templ_dir" =~ "hosts.${distro}.tmpl" ]]; then
		echo "/etc/cloud/templates/hosts.${distro}.tmpl"
	fi
}


###
# img_set_root_pw <img_file> <root pw>
#
# 'img_set_root_pw' sets the root password in the given qcow2 or raw file.
#
img_set_root_pw() {
	local img_file="$1" root_pw="$2"
	info "Setting root password"

	virt-customize -a "$img_file" --root-password "password:$root_pw"
}

###
# img_largest_partition <img_file>
#
# 'img_largest_partition' prints the /dev node of the largest partition in the
# given qcow2 or raw file
#
img_largest_partition() {
	local img_file="$1"

	echo $(virt-filesystems --long --parts --blkdevs -h -a "$img_file" | grep "/dev/sd[a-z][0-9]" | sort -k4 -hr | head -n1 | cut -d ' ' -f1)
}

###
# img_size <img_file> [bytes (optional)]
#
# 'img_size' reports the size of the image as seen by the guest in the vm
#
# sizes are shown in human readable form unless bytes is specified
#
img_size() {
	local img_file="$1" bytes="$2"

	if [[ -z "$bytes" ]]; then
		# e.g. virtual size: 32 GiB (34359738368 bytes)
		echo $(qemu-img info "$img_file" | grep "virtual size" | sed 's/virtual size: \([0-9]*\) \([KMG]\)iB ([0-9]* bytes)/\1\2/g')
	else
		echo $(qemu-img info "$img_file" | grep "virtual size" | sed 's/virtual size: [0-9]* [KMG]iB (\([0-9]*\) bytes)/\1/g')
	fi
}

###
# img_resize <img_file_orig> <img_file_new> <size>
#
# 'resize' resizes the given qcow2 or raw file growing or shrinking partitions
# and file systems inside as well.
#
# if the original image file and new image file are the same, the file is
# resized in place.
#
img_resize() {
	local img_file_orig="$1" img_file_new="$2" new_size="$3" cur_size
	local cur_size_bytes new_size_bytes
	local largest_part

	if [[ "${new_size: -1}" =~ [MKG] ]]; then
		cur_size=$(img_size $img_file_orig)
		cur_size_bytes=$(numfmt --from iec $cur_size)
		new_size_bytes=$(numfmt --from iec $new_size)
	else
		cur_size=$(img_size $img_file_orig 'bytes')
		cur_size_bytes=$cur_size
		new_size_bytes=$new_size
	fi

	echo "cur_size: $cur_size ($cur_size_bytes)"
	echo "new_size: $new_size ($new_size_bytes)"

	if  [[ $cur_size_bytes -eq $new_size_bytes ]]; then
		echo "$img_file is already $new_size"

		if [[ "$img_file_orig" != "$img_file_new" ]]; then
			cp "$img_file_orig" "$img_file_new"
		fi
		return
	elif [[ $cur_size_bytes -lt $new_size_bytes ]]; then
		largest_part=$(img_largest_partition "$img_file_orig")
		if [[ "$img_file_orig" == "$img_file_new" ]]; then
			echo "we're resizing in place"
			mv "$img_file_orig" tmp.qcow2
			qemu-img create -f qcow2 "$img_file_orig" "$new_size"
			virt-resize --expand $largest_part tmp.qcow2 "$img_file_orig"
			rm tmp.qcow2
		else
			qemu-img create -f qcow2 "$img_file_new" "$new_size"
			virt-resize --expand $largest_part "$img_file_orig" "$img_file_new"
		fi
	else
		echo "shrinking a cloud image is not supoorted at this time"
#		largest_part=$(img_largest_partition "$img_file_orig")
#		echo "largest_partition: $largest_part"
#		if [[ "$img_file_orig" == "$img_file_new" ]]; then
#			echo "we're resizing in place"
#			mv "$img_file_orig" tmp.qcow2
#			qemu-img create -f qcow2 "$img_file_orig" "$new_size"
#			virt-resize --shrink $largest_part tmp.qcow2 "$img_file_orig"
#			rm tmp.qcow2
#		else
#			qemu-img create -f qcow2 "$img_file_new" "$new_size"
#			virt-resize --shrink $largest_part "$img_file_orig" "$img_file_new"
#		fi
	fi
}

