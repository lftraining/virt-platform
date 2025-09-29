#!/bin/bash
##############################################################################
# Written by: John Bonesio
# Licensed under the GPLv2
#
# Create qcow2 disk image and cloudinit.iso files to use when creating a new VM.
#
# The qcow2 and cloudinit.iso files will work so when they're used in a new VM,
# on first start, the VM will create users, install packages, setup host names,
# create NFS mounts, setup ttys, and install the desktop enviornmaent if
# specified, among other things.
#

declare -A IMG_VARS

keep_tmps=""

#
# virt-builder might work too, but I couldn't get it to work
#


#######
# Pull in helper functions
#

#source <(cat helper_functions/*.sh)

source helper_functions/vm_image_functions.sh
source helper_functions/file_functions.sh
source helper_functions/proxmox_functions.sh
source helper_functions/msg_functions.sh
source helper_functions/str_functions.sh

# file_is_present() { echo "file functions present"; }
# msg_is_present() { echo "msg functions present"; }
# proxmox_is_present() { echo "proxmox functions present"; }
# str_is_present() { echo "str functions present"; }
# vm_is_present() { echo "vm functions present"; }

convert_str_to_multiline() {
 	local in_list="$1" prefix="$2" all_lines=""
 
 	first=1
 	for i in $in_list; do
 		if [ "$first" -eq 1 ]; then
 			all_lines=''"${prefix}${i}"
 			first=0
 		else
# 			all_lines+=''"\n${prefix}${i}"
 			all_lines="${all_lines}\n${prefix}${i}"
 		fi
 	done
 	echo "${all_lines}"
}

declare -A tools_pkg_help
tools_pkg_help["wget"]="try installing the package wget"
tools_pkg_help["mkpasswd"]="try installing the package whois"
tools_pkg_help["qemu-img"]="try installing the package qemu-utils or qemu-img"
tools_pkg_help["genisoimage"]="try installing the package genisoimage"
tools_pkg_help["virt-customize"]="try installing the package guestfs-tools"

test_tools_present() {
	local tool_list="$1" tool

	for tool in $tool_list; do
		if ! command -v $tool >/dev/null 2>&1; then
			echo "$tool not found on your system"
			echo "${tools_pkg_help[$tool]}"
		fi
	done
}

#
#
#######

###
# download the cloud file to the image we are building
download_url() {
	local url="$1" img_file="$2" tmp_file

	info "Downloading $url as $img_file"

	if [[ -n "$$3" ]]; then
		tmp_file=$(mktemp)
	else
		tmp_file="$img_file"
	fi

	wget -c -q --show-progress -N "$url" -O "$tmp_file"

	if [[ ! -f "$tmp_file" ]]; then
		error "cannot find $uri"
	fi
}

cp_qcow2_n_resize() {
	local src_img_file="$1" img_file="$2" size="$3"

	if [[ -z $(img_is_cloud_image "$src_img_file") ]]; then
		echo "possible locations to search:"
		echo "https://fedoraproject.org/cloud/download"
		echo "https://cdimage.debian.org/images/cloud/"
		error "$src_img_file does not appear to be a cloud image file."
	fi

	if [[ ! -f "$src_img_file" ]]; then
		error "cannot find $src_img_file"
	fi

	if [[ -n "$size" ]]; then
		info "resizing while copying $src_img_file to $img_file ($size)"
		img_resize "$src_img_file" "$img_file" "$size"
	else
		info "Copying $src_img_file to $img_file"

		#
		# Since the copy can take a long time use a command that is common and can show progress
		#
		#cp "$src_img_file" "$img_file"
		rsync -ah --progress "$src_img_file" "$img_file"
	fi
}

###
# oneliner must be <section>: <value>
ci_ensure_section_oneliner() {
	local ci_file=$1 oneliner=$2 section="${2%%:*}"

        if ! grep -q "^$section$" "$ci_file" ; then
		echo -e "$oneliner" >> "$ci_file"
	fi
}

###
ci_ensure_section() {
	local ci_file=$1 section=$2

        if ! grep -q "^${section}:\$" "$ci_file" ; then
		echo -e "$section:" >> "$ci_file"
	fi
}

###
ci_create_template() {
	local ci_dir_name="$1" img_file="$2" base_file="$(basename_no_ext $2)"
	info "Createing cloud-init template"

	if [[ -d $ci_dir_name ]]; then
		rm -r $ci_dir_name
	fi
	mkdir $ci_dir_name
	# meta-data
	echo "#meta-data" > $ci_dir_name/meta-data
	echo "instance-id: $base_file" >> $ci_dir_name/meta-data
	echo "local-hostname: $base_file" >> $ci_dir_name/meta-data

	# user-data
	echo '#cloud-config' > $ci_dir_name/user-data
}

###
ci_add_hostname() {
	local ci_file="$1" hostname="$2"

	if [[ -z "$hostname" ]]; then return; fi
	ci_ensure_section_oneliner "$ci_file" "hostname: $hostname"
}

###
ci_add_timezone() {
	local ci_file="$1" tz="$2"

	if [[ -z "$tz" ]]; then return; fi
	ci_ensure_section_oneliner "$ci_file" "timezone: $tz"
}

###
ci_add_keyboard_layout() {
	local ci_file="$1" layout="$2"

	if [[ -z "$layout" ]]; then return; fi
	info "Adding keyboard layout: $laout"

	ci_ensure_section "$ci_file" "keyboard"

	lines=(
		"  layout: $layout"
	)

	nelem=${#lines[@]}
	if (( nelem > 1 )); then
		all_lines=$(printf -- "  %s\\\n" "${lines[@]:0:nelem-1}")
	fi
	all_lines+=$(printf -- "  %s" "${lines[@]: -1}")

        file_add_after "$ci_file" "$all_lines" "/keyboard:/"
}


fedora_user_groups=""
debian_user_groups="users"

fedora_sudo_group="wheel"
debian_sudo_group="sudo"

###
ci_add_user_accnt() {
	local ci_file="$1" user="$2" pw="$3" sudoer="$4" distro="$5" lines enc_pw nelem

	if [[ -z "$user" ]]; then return; fi
	info "Adding user $user to cloud-init"

	ci_ensure_section "$ci_file" "users"

	enc_pw=$(mkpasswd -m sha-512 "$pw")

	user_groups_name="${distro}_user_groups"
	user_groups="${!user_groups_name}"

	sudo_group_name="${distro}_sudo_group"
	sudo_group="${!sudo_group_name}"

	lines=(
		"- name: $user"
		"  lock_passwd: false"
		"  passwd: '$enc_pw'"
		"  shell: /bin/bash"
	)

	if [[ "$user" != "root" ]]; then
		if [[ -n "$sudoer" ]]; then
			lines+=("  groups: ${user_groups}${user_groups:+","}${sudo_group}")
			if [[ "$sudoer" == "nopwd" ]]; then
				lines+=("  sudo: ALL=(ALL) NOPASSWD:ALL")
			fi
		else
			lines+=("  groups: $user_groups")
		fi
	fi

	nelem=${#lines[@]}
	if (( nelem > 1 )); then
		all_lines=$(printf -- "  %s\\\n" "${lines[@]:0:nelem-1}")
	fi
	all_lines+=$(printf -- "  %s" "${lines[@]: -1}")
        file_add_after "$ci_file" "$all_lines" "/users:/"
}

###
ci_add_root_pw() {
	local ci_file="$1" root_pw="$2" lines enc_pw nelem

	if [[ -z "$root_pw" ]]; then return; fi
	info "Adding root password to cloud-init"

	ci_ensure_section "$ci_file" "chpasswd"

	enc_pw=$(mkpasswd -m sha-512 "$pw")

	lines=(
		"expire: false"
		"list:"
		"  root:$enc_pw"
	)

	nelem=${#lines[@]}
	if (( nelem > 1 )); then
		all_lines=$(printf -- "  %s\\\n" "${lines[@]:0:nelem-1}")
	fi
	all_lines+=$(printf -- "  %s" "${lines[@]: -1}")
        file_add_after "$ci_file" "$all_lines" "/chpasswd:/"
}

###
ci_add_ssh_pwauth() {
	local ci_file="$1"

	ci_ensure_section_oneliner "$ci_file" "ssh_pwauth: true"
}


fedora_base_pkgs="nfs-utils vim"
debian_base_pkgs="nfs-common vim"

fedora_dev_pkgs="bc bison flex kernel-devel elfutils-libelf-devel openssl-devel lz4 lz4-libs"
debian_dev_pkgs="bc bison flex build-essential libelf-dev libssl-dev lz4"

###
ci_add_packages() {
	local ci_file="$1" distro="$2" lines

	if [[ -z "$distro" ]]; then
		error "Can't add packages with unknown distro"
	fi

	base_pkg_list_name="${distro}_base_pkgs"
	base_packages="${!base_pkg_list_name}"

	dev_pkg_list_name="${distro}_dev_pkgs"
	dev_packages="${!dev_pkg_list_name}"

	packages="$base_packages $dev_packages"

	info "Adding packages: $packages"

	ci_ensure_section_oneliner "$ci_file" "package_update: true"
	ci_ensure_section_oneliner "$ci_file" "package_upgrade: true"
	ci_ensure_section "$ci_file" "packages"

	lines=$(convert_str_to_multiline "$packages" '  - ')

        file_add_after "$ci_file" "$lines" "/packages:/"

	ci_ensure_section_oneliner "$ci_file" "package-update-upgrade-install: true"
}

###
ci_add_hosts() {
	local ci_file="$1" host_list="$2" lines all_lines nelem next_host

	if [[ -z "$host_list" ]]; then return; fi
	info "Adding hosts"

	ci_ensure_section "$ci_file" "write_files"

	lines=(
		"- path: ${IMG_VARS[HOSTS_FILE]}"
		'  append: true'
		'  content: |'
	)

	while [[ -n "$host_list" ]]; do
		next_host=$(str_first_field "$host_list" '|')
		host_list=$(str_shift "$host_list" '|')

		lines+=("    $next_host")
	done

	nelem=${#lines[@]}
	if (( nelem > 1 )); then
		all_lines=$(printf -- "  %s\\\n" "${lines[@]:0:nelem-1}")
	fi
	all_lines+=$(printf -- "  %s" "${lines[@]: -1}")
        file_add_after "$ci_file" "$all_lines" "/write_files:/"
}

###
ci_add_nfs() {
	local ci_file="$1" nfs_list="$2" lines all_lines elem
	local next_nfs path

	if [[ -z "$nfs_list" ]]; then return; fi
	info "Adding NFS mounts"

	ci_ensure_section "$ci_file" "runcmd"

	lines=()

	while [[ -n "$nfs_list" ]]; do
		next_nfs=$(str_first_field "$nfs_list" '|')
		nfs_list=$(str_shift "$nfs_list" '|')

		path=$(str_last_field "$next_nfs")
		lines+=("- mkdir -p $path")
		lines+=("- chmod 777 $path")
	done

	nelem=${#lines[@]}
	if (( nelem > 1 )); then
		all_lines=$(printf -- "  %s\\\n" "${lines[@]:0:nelem-1}")
	fi
	all_lines+=$(printf -- "  %s" "${lines[@]: -1}")
        file_add_after "$ci_file" "$all_lines" "/runcmd:/"

	ci_ensure_section "$ci_file" "write_files"

	lines=(
		'- path: /etc/fstab'
		'  append: true'
		'  content: |'
	)

	nfs_list="$2"
	while [[ -n "$nfs_list" ]]; do
		next_nfs=$(str_first_field "$nfs_list" '|')
		nfs_list=$(str_shift "$nfs_list" '|')

		lines+=("    $next_nfs nfs soft 0 0")
	done

	nelem=${#lines[@]}
	if (( nelem > 1 )); then
		all_lines=$(printf -- "  %s\\\n" "${lines[@]:0:nelem-1}")
	fi
	all_lines+=$(printf -- "  %s" "${lines[@]: -1}")
        file_add_after "$ci_file" "$all_lines" "/write_files:/"
}


fedora_desktop_pkgs='fedora-release-workstation @workstation-product-environment'
debian_desktop_pkgs="task-gnome-desktop"

fedora_pkg_tool='dnf'
debian_pkg_tool='DEBIAN_FRONTEND="noninteractive" apt-get'

fedora_pkg_tool_short='dnf'
debian_pkg_tool_short='apt-get'

fedora_install_kw='workstation'
debian_install_kw='task-gnome-desktop'

fedora_gdm='gdm'
debian_gdm='gdm3'

fedora_gdm_conf="/etc/$fedora_gdm/custom.conf"
debian_gdm_conf="/etc/$debian_gdm/daemon.conf"

ci_add_desktop_config() {
	local ci_file="$1" user="$2" distro="$3" autorun="$4" gnome_setting_list="$5" nelem lines all_lines
	local gnome_auto_login="" gnome_screen_blank=""

	info "Adding /root/desktop_config.sh"

	ci_ensure_section "$ci_file" "write_files"

	desktop_pkg_list_name="${distro}_desktop_pkgs"
	desktop_pkgs="${!desktop_pkg_list_name}"

	pkg_tool_name="${distro}_pkg_tool"
	pkg_tool="${!pkg_tool_name}"
	pkg_tool_short_name="${distro}_pkg_tool_short"
	pkg_tool_short="${!pkg_tool_short_name}"
	pkg_install_kw_name="${distro}_install_kw"
	pkg_install_kw="${!pkg_install_kw_name}"

	gdm_conf_name="${distro}_gdm_conf"
	gdm_conf="${!gdm_conf_name}"

	gdm_name="${distro}_gdm"
	gdm="${!gdm_name}"

	gnome_settings="$gnome_setting_list"
	while [[ -n "$gnome_settings" ]]; do
		next_opt=$(str_first_field "$gnome_settings" '|')
		gnome_settings=$(str_shift "$gnome_settings" '|')

		case $next_opt in
			auto-login) gnome_auto_login='true' ;;
			screen-blank-off) gnome_screen_blank='0' ;;
			*) echo "unrecognized gnome setting: $next_top"
		esac
	done

	lines=(
		'- path: /root/desktop_config.sh'
		'  content: |'
		'    #!/bin/bash'
	)
	if [[ "$distro" = "debian" ]]; then
		lines+=(
		'    DEBIAN_FRONTEND="noninteractive" dpkg --configure -a'
		)
	fi
	prefix="    $pkg_tool install -y "
	for pkg_name in $desktop_pkgs; do
		lines+=("${prefix}$pkg_name")
	done
	lines+=(
		'    echo "Waiting for packages to finish installing..."'
		"    while ps -A | grep -v 'grep' | grep -q $pkg_tool_short; do echo -n '.'; done"
	)
	if [[ -n "$gnome_auto_login" || -n "$gnome_screen_blank" ]]; then
		if [[ -n "$gnome_auto_login" ]]; then
			lines+=(
			"    sed -i -e/\\\\\\\\[daemon\\\\\\\\]/a\ AutomaticLogin=$user $gdm_conf"
			"    sed -i -e/\\\\\\\\[daemon\\\\\\\\]/a\ AutomaticLoginEnable=True $gdm_conf"
			)
		fi
		if [[ -n "$gnome_screen_blank" ]]; then
			if [[ "$distro" = "debian" ]]; then
			lines+=(
			'    echo user-db:user > /etc/dconf/profile/user'
			'    echo system-db:local >> /etc/dconf/profile/user'
			)
			fi
			lines+=(
			'    mkdir -p /etc/dconf/db/local.d'
			'    echo "[org/gnome/desktop/session]" > /etc/dconf/db/local.d/01-custom-settings'
			'    echo "idle-delay=uint32 0" >> /etc/dconf/db/local.d/01-custom-settings'
			)
		fi
		lines+=(
		'    dconf update'
		)
	fi
	lines+=(
		'    systemctl set-default graphical.target'
		"    systemctl enable $gdm"
		'    reboot'
		'  owner: root:root'
		"  permissions: '0755'"
	)

	nelem=${#lines[@]}
	if (( nelem > 1 )); then
		all_lines=$(printf -- "  %s\\\n" "${lines[@]:0:nelem-1}")
	fi
	all_lines+=$(printf -- "  %s" "${lines[@]: -1}")
        file_add_after "$ci_file" "$all_lines" "/write_files:/"


	if [[ "$autorun" = "auto" ]]; then
		# automatically run desktop_config.sh first startup
		ci_ensure_section "$ci_file" "runcmd"

		all_lines=""
		lines=(
			'- /root/desktop_config.sh'
		)
		nelem=${#lines[@]}
		if (( nelem > 1 )); then
			all_lines=$(printf -- "  %s\\\n" "${lines[@]:0:nelem-1}")
		fi
		all_lines+=$(printf -- "  %s" "${lines[@]: -1}")
		file_add_after_at_section_end $ci_file "$all_lines" "/runcmd:/"
	fi
}

###
ci_start_ssh() {
	local ci_file="$1" nelem all_lines
	info "Adding ssh startup"

	ci_ensure_section "$ci_file" "runcmd"

	lines=(
		'- systemctl start ssh'
	)

	nelem=${#lines[@]}
	if (( nelem > 1 )); then
		all_lines=$(printf -- "  %s\\\n" "${lines[@]:0:nelem-1}")
	fi
	all_lines+=$(printf -- "  %s" "${lines[@]: -1}")
        file_add_after "$ci_file" "$all_lines" "/runcmd:/"
}

###
ci_enable_serial_getty() {
	local ci_file="$1" tty_list="$2" nelem all_lines next_tty

	info "Setting up ttys"

	ci_ensure_section "$ci_file" "runcmd"

	lines=()

	while [[ -n "$tty_list" ]]; do
		next_tty=$(str_first_field "$tty_list" '|')
		tty_list=$(str_shift "$tty_list" '|')

		lines+=("- systemctl enable \"serial-getty@$next_tty\"")
	done

	nelem=${#lines[@]}
	if (( nelem > 1 )); then
		all_lines=$(printf -- "  %s\\\n" "${lines[@]:0:nelem-1}")
	fi
	all_lines+=$(printf -- "  %s" "${lines[@]: -1}")
        file_add_after "$ci_file" "$all_lines" "/runcmd:/"
}

###
ci_add_wait_msg() {
	local ci_file="$1" lines all_lines nelem

	info "Adding wait message to first login"

	ci_ensure_section "$ci_file" "write_files"

	lines=(
	'- path: /etc/profile.d/first_login_message.sh'
	'  content: |'
	'    #!/bin/bash'
	'    cloudinit_status() {'
	'        local status_line'
	'        status_line="$(cloud-init status 2>&1)"'
	'        if [[ "$status_line" =~ "command not found" ]]; then'
	'            echo "Not present"'
	'            return'
	'        fi'
	'        echo "${status_line##*: }"'
	'    }'
	'    # If there is cloud-init on this system'
	'    if [ -f /run/cloud-init/status.json ]; then'
	'        # possible status values:'
	'        # Not started, Running, Done, Error - done, Error - running,'
	'        # Degraded done, Degraded running, Disabled'
	'        if [[ $(cloudinit_status) =~ [Rr]unning ]]; then'
	'            # we need to wait'
	'            echo "Waiting for cloud-init to complete."'
	'            echo "This could take a while if, for example, the desktop is being installed."'
	'            echo "..."'
	'            cloud-init status --wait'
	'            echo "cloud-init complete. You can now proceed."'
	'        fi'
	'    fi'
	'  owner: root:root'
	"  permissions: '0755'"
	)

	nelem=${#lines[@]}
	if (( nelem > 1 )); then
		all_lines=$(printf -- "  %s\\\n" "${lines[@]:0:nelem-1}")
	fi
	all_lines+=$(printf -- "  %s" "${lines[@]: -1}")
        file_add_after "$ci_file" "$all_lines" "/write_files:/"
}

###
ci_generate_iso() {
	local ci_iso_name="$1" ci_dir_name="$2"
	info "Generating $ci_iso_name"

	cd $ci_dir_name;
	info "genisoimage -output ../$ci_iso_name -input-charset utf-8 -volid cidata -joliet -rock user-data meta-data"
	genisoimage -output ../$ci_iso_name -input-charset utf-8 -volid cidata -joliet -rock user-data meta-data
	cd ..
}
ci_delete_template() {
	local ci_dir_name="$1"

	$RM -r $ci_dir_name
}

###
# create the cloudinit.iso file
create_cloud_init() {
	local img_file="${IMG_VARS[IMAGE_NAME]}" ci_file="${IMG_VARS[CI_DIR_NAME]}/user-data"

	# The template is crated based on the image name we're creating
	ci_create_template "${IMG_VARS[CI_DIR_NAME]}" "$img_file"
	ci_add_hostname "$ci_file" "$(basename_no_ext $img_file)"
	ci_add_timezone "$ci_file" "${IMG_VARS[TZ]}"
# for now just let the keyboard settings use default
#	ci_add_keyboard_layout "$ci_file" "us"
	if [[ -n "${IMG_VARS[USER]}" ]]; then
		ci_add_user_accnt "$ci_file" "${IMG_VARS[USER]}" "${IMG_VARS[PASSWD]}" "${IMG_VARS[SUDOER]}" "${IMG_VARS[DISTRO]}"
	fi
	ci_add_ssh_pwauth "$ci_file"
	ci_add_packages "$ci_file" "${IMG_VARS[DISTRO]}"
	ci_add_hosts "$ci_file" "${IMG_VARS[HOSTS]}"
	ci_add_nfs "$ci_file" "${IMG_VARS[NFS]}"

	if [[ -n "${IMG_VARS[DESKTOP]}" ]]; then
		ci_add_desktop_config "$ci_file" "${IMG_VARS[USER]}" "${IMG_VARS[DISTRO]}" "${IMG_VARS[AUTOINSTALL]}"  "${IMG_VARS[GNOME_SETTINGS]}" 
	fi
	ci_start_ssh "$ci_file" 
	ci_enable_serial_getty "$ci_file" "${IMG_VARS[STTY]}"

	ci_add_wait_msg "$ci_file" 

	ci_generate_iso "${IMG_VARS[CI_ISO_NAME]}" "${IMG_VARS[CI_DIR_NAME]}"
	ci_delete_template "${IMG_VARS[CI_DIR_NAME]}"
}

###
# Create the new qcow2 file with the root pw set
create_image() {
	local src_qcow2="${IMG_VARS[SRC_URI]}"

	if [[ "$(str_is_url "$uri")" == "true" ]]; then
		src_qcow2='tmp.qcow2'
		download_url "${IMG_VARS[SRC_URI]}" "$src_qcow2"
	fi

	# figure out the distro
	if [[ -z "${IMG_VARS[DISTRO]}" ]]; then
		echo "discovering distro..."
		distro=$(img_find_distro_type "$(basename $src_qcow2)")
		echo "distro detected: $distro"

		if [[ -z "$distro" ]]; then
			error "Can't auto determine distribution. Try using --distro option"
		fi
		IMG_VARS[DISTRO]="$distro"
	fi

	cp_qcow2_n_resize "$src_qcow2" "${IMG_VARS[IMAGE_NAME]}" "${IMG_VARS[SIZE]}"

	#
	# We could just set the root password in the cloud init program
	# But this way even if cloud init fails we can still login as root
	#
	if [[ -n "${IMG_VARS[ROOT_PASSWD]}" ]]; then
		img_set_root_pw "${IMG_VARS[IMAGE_NAME]}" "${IMG_VARS[ROOT_PASSWD]}"
	fi
}

###
skip_print_settings=''
print_settings() {
	if [[ "$skip_print_settings" == 'skip' ]]; then return; fi

	local nfs_list next_nfs
	local host_list next_host
	local tty_list next_tty
	local gnome_list next_gnome

	if [[ -n "${IMG_VARS[SIZE]}" ]]; then
		echo "creating ${IMG_VARS[SIZE]} file, ${IMG_VARS[IMAGE_NAME]}"
	else
		echo "creating ${IMG_VARS[IMAGE_NAME]} (same size as src file)"
	fi
	echo "   from ${IMG_VARS[SRC_URI]}"
	echo ""
	echo "also creating cloud-init file ${IMG_VARS[CI_ISO_NAME]} for use with ${IMG_VARS[DISTRO]}"
	echo "   with the following options:"
	echo "   root pw: ${IMG_VARS[ROOT_PASSWD]}"
	echo "   user: ${IMG_VARS[USER]}, pw: ${IMG_VARS[PASSWD]}, sudoer: ${IMG_VARS[SUDOER]}"
	echo "   timezone: ${IMG_VARS[TZ]}"

	tty_list="${IMG_VARS[STTY]}"
	while [[ -n "$tty_list" ]]; do
		next_tty=$(str_first_field "$tty_list" '|')
		tty_list=$(str_shift "$tty_list" '|')

		echo "   tty: $next_tty"
	done

	host_list="${IMG_VARS[HOSTS]}"
	while [[ -n "$host_list" ]]; do
		next_host=$(str_first_field "$host_list" '|')
		host_list=$(str_shift "$host_list" '|')

		echo "   host: $next_host"
	done

	nfs_list="${IMG_VARS[NFS]}"
	while [[ -n "$nfs_list" ]]; do
		next_nfs=$(str_first_field "$nfs_list" '|')
		nfs_list=$(str_shift "$nfs_list" '|')

		echo "   nfs: $next_nfs"
	done

	echo "   desktop: ${IMG_VARS[DESKTOP]}, install: ${IMG_VARS[AUTOINSTALL]}"
	if [[ -n "${IMG_VARS[DESKTOP]}" ]]; then
		echo "   gnome settings:"

		gnome_list="${IMG_VARS[GNOME_SETTINGS]}"
		while [[ -n "$gnome_list" ]]; do
			next_gnome=$(str_first_field "$gnome_list" '|')
			gnome_list=$(str_shift "$gnome_list" '|')

			echo "       $next_gnome"
		done

	fi
	if [[ -n "${IMG_VARS[KEEPTMP]}" ]]; then
		echo "   intermediate temporary files and directories will be saved"
	fi
}

###
# LFD441 defaults
set_lfd441_defaults() {
	IMG_VARS[USER]="student"
	IMG_VARS[PASSWD]="I<3Penguins"
	IMG_VARS[SUDOER]="nopwd"
	IMG_VARS[ROOT_PASSWD]="Penguin2014"
	# if desktop selected ...
	IMG_VARS[GNOME_SETTINGS]='auto-login|screen-blank-off'
	IMG_VARS[TZ]="America/Chicago"
	IMG_VARS[HOSTS]="10.10.10.1 proxmox|10.10.10.2 pihole"
	IMG_VARS[NFS]="proxmox:/srv/LFT /srv/LFT"
	IMG_VARS[STTY]='ttyS0'
	IMG_VARS[SIZE]="32G"
	IMG_VARS[CI_DIR_NAME]="cloudinit_config"
	IMG_VARS[CI_ISO_NAME]="cloud-init.iso"
}


##
usage() {
	CMDBASE=$(basename $0)
	echo "$CMDBASE creates and configures a qcow2 image from a base cloud image"
	echo ""
	echo "Usage: $CMDBASE [options] <cloud image (url or filepath)> <new filename>"
	echo "      --desktop auto|manual          install gnome desktop environment"
	echo "                                     run install script auto or namual"
	echo "      --gnome auto-login|"
	echo "              screen-blank-off       Setting gnome desktop settings"
	echo "                                     multiple --gnome options possible"
	echo "      --user <user name>             specify the user account name"
	echo "      --passwd <user password>       specify the user account password"
	echo "      --sudoer nopwd|yes             user can use sudo with or w/o password"
	echo "      --root-passwd <root password>  specify the root account password"
	echo "      --tz <timezone text>           specify the timezone"
	echo "      --host <ip> <hostname>         specify a hostname for /etc/hosts"
	echo "                                     multiple --host options possible"
	echo "      --nfs <server> <mount>         add an nfs share to auto mount"
	echo "                                     multiple --nfs options possible"
	echo "      --serial-tty <serial dev>      add tty (without /dev/) on serial port"
	echo "      --size <new img size>          specify size e.g. 32G"
	echo "      --keep-tmps                    don't delete temporary files (debugging)"
	echo "      --lfd441                       pick defaults for LFD441"
	echo "                                     --desktop may still be needed"
	echo "      --help                         print this help message"
	echo ""
	echo "   [cloud init name.iso] example: cloud-init.iso"
	echo "   If [cloud init name.iso] is not provided the name will be"
	echo "   based on the basenme of the target qcow2 image, e.g.: cloudinit-fedora42.iso"

IMG_VARS[CI_ISO_NAME]="cloud-init_${img_base_name}.iso"
	exit
}


###
# Script starts here
###

test_tools_present "wget genisoimage qemu-img virt-customize"

# grab the options
CMDOPTS="$*"
while [[ $# -gt 0 ]]; do
	case "$1" in
		--distro) IMG_VARS[DISTRO]="$2"; echo "distro: ${IMG_VARS[DISTRO]}"; shift ;;
		--desktop) IMG_VARS[DESKTOP]="gnome"; IMG_VARS[AUTOINSTALL]="$2"; shift ;;
		--gnome)
		    IMG_VARS[GNOME_SETTINGS]=$(str_append "${IMG_VARS[GNOME_SETTINGS]}" "$2" '|')
		    shift ;;
		--user) IMG_VARS[USER]="$2"; shift ;;
		--passwd|--password) IMG_VARS[PASSWD]="$2"; shift ;;
		--sudoer) IMG_VARS[SUDOER]="$2"; shift ;;
		--root-pw|--root-passwd|--root-password) IMG_VARS[ROOT_PASSWD]="$2"; shift ;;
		--tz) IMG_VARS[TZ]="$2"; shift ;;
		--host)
		    IMG_VARS[HOSTS]=$(str_append "${IMG_VARS[HOSTS]}" "$2 $3" '|')
		    shift; shift; ;;
		--nfs)
		    IMG_VARS[NFS]=$(str_append "${IMG_VARS[NFS]}" "$2 $3" '|')
		    shift; shift; ;;
		--size) IMG_VARS[SIZE]="$2"; shift ;;
		--serial-tty)
		    IMG_VARS[STTY]=$(str_append "${IMG_VARS[STTY]}" "$2" '|')
		    shift; ;;
		--keep-tmps) IMG_VARS[KEEP_TMP]="true"; MV="cp" RM=":" ;;
		--lfd441) set_lfd441_defaults; ;;
		--no-print-settings) skip_print_settings='skip' ;;
		--help) usage ;;
		--*) echo "unknown option $1"; usage ;;
		*) break ;;
	esac
	shift
done

# check for bad options
if [[ -n "${IMG_VARS[USER]}" ]]; then
	if [[ -z "${IMG_VARS[PASSWD]}" ]]; then
		echo "user specified without passsword, using pw 'qwerty'"
		IMG_VARS[PASSWD]='qwerty'
	fi
fi

if [[ $# -lt 2 ]]; then
	usage;
fi

IMG_VARS[SRC_URI]=$1
IMG_VARS[IMAGE_NAME]=$2

img_base_name=$(basename_no_ext "${IMG_VARS[IMAGE_NAME]}")

IMG_VARS[CI_DIR_NAME]="cloudinit_config-${img_base_name}"
IMG_VARS[CI_ISO_NAME]="cloudinit-${img_base_name}.iso"

print_settings

# create the new qcow2 file with nimial setup
create_image

# get the hosts file (at some point we may need more than just the host name)
IMG_VARS[HOSTS_FILE]=$(img_get_hosts_file "${IMG_VARS[IMAGE_NAME]}" "${IMG_VARS[DISTRO]}")

# then create the cloud-init.iso file with all the settings we want
create_cloud_init

### TODO
# Add option for keyboard layout
# (Maybe?) Add auto run of something to run systemctl clout-init.service (maybe? or something similar)
