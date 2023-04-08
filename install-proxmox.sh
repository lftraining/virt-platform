#!/bin/bash
##############################################################################
# Written by: Behan Webster
# Licensed under the GPLv2
#
# Install proxmox on new Debian install
#

set -e

VERSION=2.0

RED="\e[0;31m"
GREEN="\e[0;32m"
YELLOW="\e[0;33m"
#CYAN="\e[0;36m"
#BLUE="\e[0;34m"
BACK="\e[0m"

ALGO="ed25519"
HOSTS="/etc/hosts"
SSHFILE="$HOME/.ssh/id_$ALGO"
VERBOSE=

MKDIR="verbose mkdir -p"
RM="verbose rm -f"
SED="verbose sed"
WGET="verbose wget --continue --quiet --show-progress --progress=bar"

CMUSERNAME="LFtraining"
CMPASSWORD="Penguin2014"

SOURCESD="/etc/apt/sources.list.d"
ENTERPRISE="$SOURCESD/pve-enterprise.list"
PVELIST="$SOURCESD/pve-install-repo.list"

CMD="install-proxmox"
CACHE="$HOME/.cache/$CMD"
CONFIG="$HOME/.config/$CMD"

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
	#echo -e "${YELLOW}##############################################################################$BACK" >&2
	echo -e "${YELLOW}W:" "$@" "$BACK" >&2
	#echo -e "${YELLOW}##############################################################################$BACK" >&2
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
generate_password() {
	< /dev/urandom tr -dc _A-Z-a-z-0-9 | head "-c${1:-16}";echo;
}

##############################################################################
get_password() {
	PASSWD="$HOME/passwd.txt"
	if [[ ! -e $PASSWD ]] ; then
		generate_password 16 >"$PASSWD"
	fi
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
	PASSWORD="$(get_password)"
}

##############################################################################
read_config() {
	default_config

	local CONF FILES="$CONFIG/defaults.conf $HOME/.$CMD.conf"
	for CONF in $FILES ; do
		if [[ -f "$CONF" ]] ; then
			# shellcheck disable=SC1090
			. "$CONF"
		fi
	done
}

##############################################################################
install_digitalocean_extras() {
	banner "Install Digital Ocean Extras"
	[[ ! -f /opt/digitalocean/bin/droplet-agent ]] || return 0

	# Droplet-agent
	wget -qO- https://repos-droplet.digitalocean.com/install.sh | sudo bash
	# Insights
	wget -qO- https://repos.insights.digitalocean.com/install.sh | sudo bash
}

##############################################################################
get_ip() {
	ip route get 1.1.1.1 | grep -oP 'src \K\S+'
}

##############################################################################
add_to_hosts() {
	local IP=${1:?}; shift
	local FQDN=${1:?}; shift
	local ENTRY="$IP $FQDN ${FQDN%%.*} $*"

	if grep -q "^$IP" "$HOSTS" ; then
		$SED -i "s/^${IP}[^0-9].*$/$ENTRY/" "$HOSTS"
	else
		$SED -i "$ a $ENTRY" "$HOSTS"
	fi
}

##############################################################################
update_hosts_entry() {
	local IP=$1 FQDN=$2
	local ENTRY="$IP $FQDN ${FQDN%%.*}"

	banner "Update $HOSTS with $IP"
	if grep -q "^$IP" "$HOSTS" ; then
		$SED -i "s/^${IP}[^0-9].*$/$ENTRY/" "$HOSTS"
	elif grep -q '127\.0\.1\.1' "$HOSTS" ; then
		$SED -i "s/127\\.0\\.1\\.1.*$/$ENTRY/" "$HOSTS"
	elif grep -q '127\.0\.0\.1' "$HOSTS" ; then
		$SED -i "/127\\.0\\.0\\.1/i $ENTRY" "$HOSTS"
	else
		$SED -i "$ a $ENTRY" "$HOSTS"
	fi

	if [[ -z $TEST ]] ; then
		local RESULT
		RESULT="$(hostname --ip-address)"
		if [[ $RESULT != "$IP" ]] ; then
			error "$HOSTS: Update failed"
		fi
	fi
}

##############################################################################
run_apt() {
	DEBIAN_FRONTEND=noninteractive verbose apt-get --quiet --assume-yes --no-install-recommends "$@"
}

##############################################################################
#generate_name() {
#	grep -E '^[a-z]{5,8}$' /usr/share/dict/words | grep -Ev '[^e]ed$|.{2,}(i)*est$|.{2,}(i)*er$|ily$|.{2,}ish$|.{2,}ing$|ly$|s$|ty$|abort|abuse|adult|alcohol|devil|flesh' | shuf -n 1 -
#}

HOSTNAMES="$CACHE/hostnames.txt.xz"
##############################################################################
get_hostname_list() {
	#local URL="http://training.linuxfoundation.org/cm/images"
	local URL="http://images.lf.training"

	$MKDIR "${HOSTNAMES%/*}"
	$WGET --no-check-certificate --user="$CMUSERNAME" --password="$CMPASSWORD" -O "$HOSTNAMES" "$URL/${HOSTNAMES##*/}"
}

##############################################################################
new_hostname() {
	local IP=$1 HOST FQDN
	banner "New Hostname"
	get_hostname_list
	while true ; do
		HOST="$(xzcat "$HOSTNAMES" | shuf -n 1 -)"
		FQDN="$HOST.$DOMAIN"
		info "Trying $FQDN"
		if host "$FQDN" | grep -q "^$FQDN has address $IP$" ; then
			info "$FQDN already set to $IP"
		elif host "$FQDN" | grep -q "not found" ; then
			info "$FQDN available"
		else
			continue
		fi

		verbose hostnamectl set-hostname "$HOST"
		update_hosts_entry "$IP" "$FQDN"
		HOSTNAME="$HOST"
		return
	done
}

##############################################################################
update_hostname() {
	banner "Update Hostname"

	if grep -q "^$IP.*$DOMAIN" "$HOSTS" ; then
		warn "$HOSTNAME already set to $IP"
	else
		new_hostname "$IP"
	fi
}

##############################################################################
update_hosts() {
	IP="$(get_ip)"
	update_hostname
	add_to_hosts "$NETWORK.1" "proxmox"
	add_to_hosts "$NETWORK.2" "pihole"
}

##############################################################################
setup_ssh_root() {
	banner "Setup ssh for root"
	local SSHD="/etc/ssh/sshd_config"
	local PRL="PermitRootLogin"

	if grep -q "^$PRL yes" "$SSHD" ; then
		banner "Setup ssh as word with only SSH key"
		$SED -i "s/^$PRL yes/$PRL without-password/" "$SSHD"
		info "Restarting sshd"
		verbose systemctl restart ssh
	else
		warn "SSH config already configured"
	fi

	if [[ -z ${PASSWORD:-} ]] ; then
		error "No PASSWORD set"
	#elif grep -q "^root:.:" /etc/shadow ; then
	else
		info "Set root password"
		if [[ -z $TEST ]] ; then
			chpasswd <<<"root:$PASSWORD"
		else
			verbose "chpasswd <<<root:$PASSWORD"
		fi
		warn "Root password already set"
	fi

	if [[ -f "$SSHFILE" ]] ; then
		warn "Existing root ssh $ALGO key"
	else
		info "Generating root ssh $ALGO key"
		verbose ssh-keygen -t "$ALGO" -f "$SSHFILE" -N ""
	fi
}

##############################################################################
install_proxmox_sources() {
	banner "Install Proxmox sources"
	local OSRELEASE="/etc/os-release"
	if [[ -e $OSRELEASE ]] ; then
		# shellcheck disable=SC1090
		. "$OSRELEASE"
	else
		VERSION_CODENAME="$(lsb_release -c -s)"
	fi

	local REPO="http://download.proxmox.com/debian/pve"
	local KEY="http://download.proxmox.com/debian/proxmox-release-$VERSION_CODENAME.gpg"
	if [[ -z $TEST && ! -e $PVELIST ]] ; then
		echo "deb $REPO $VERSION_CODENAME pve-no-subscription" >"$PVELIST"
		$WGET -O- "$KEY" 2>/dev/null | verbose apt-key add -
	fi
}

##############################################################################
update_debian() {
	banner "Update Debian packages"
	$RM "$ENTERPRISE"
	run_apt update
}

##############################################################################
setup_sources() {
	install_proxmox_sources
	update_debian
}

##############################################################################
install_packages() {
	if dpkg --get-selections postfix | grep -q install ; then
		warn "Postfix already installed"
	else
		banner "Install Postfix"
		verbose debconf-set-selections <<< "postfix postfix/mailname string $HOSTNAME"
		verbose debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Local only'"
	fi

	banner "Install extra Debian packages"
	warn "Your connection will break as network changes are made.\nReconnect when you can and run byobu"
	run_apt install ifupdown2
	run_apt install chrony etckeeper ksmtuned lsof mosh nfs-kernel-server nmap postfix rsync ssh sudo unattended-upgrades vim vim-addon-manager vim-youcompleteme bc bison build-essential flex libelf-dev htop libncurses-dev libssl-dev lz4 proxmox-ve
	$RM "$ENTERPRISE"
	run_apt full-upgrade

	verbose vim-addons install youcompleteme
	local VIMRC="$HOME/.vimrc"
	touch "$VIMRC"
	grep -q encoding= "$VIMRC" || cat <<END >>"$VIMRC"
set encoding=utf-8
END
}

##############################################################################
check_kernel_version() {
	local KVER
	KVER="$(uname -r | sed -E -e 's/^([0-9]+\.[0-9]+)\..*$/\1/')"

	if [[ $KVER != 5.15 ]] ; then
		warn "You need to reboot before continuing"
		info "Once you reboot, run install-templates.sh"
		info "$ reboot"
		info "$ ssh root@$IP"
		info "$ $(dirname "$0")/install-templates.sh"
		exit 0
	fi
}

##############################################################################
wait_for_git() {
	banner "Waiting for git to finish in the other tab"
	info "ctrl-a 1 to get to that tab. ctrl-a 0 to come back"
	while pidof -q git ; do
		echo -n '.'
		sleep 1
	done
	echo
}

##############################################################################
#welcome() {
#	banner "visit https://$IP:8006/ in your browser"
#	info "Login as root, password $PASSWORD and Realm set to 'Linux PAM standard authentication'"
#	info "If your instructor can set $HOSTNAME.$DOMAIN to point to $IP you can then setup Letsencrypt"
#}

##############################################################################
do_the_thing() {
	update_hosts
	setup_ssh_root
	setup_sources
	install_packages
	install_digitalocean_extras
	wait_for_git
	#welcome
	check_kernel_version
}

##############################################################################
run_thing_in_byobu() {
	local DIR="${0%/*}"
	local GETKERN="${DIR:-.}/get-kernel.sh"
	local GETISOS="${DIR:-.}/get-isos.sh"
	local GETMPLS="${DIR:-.}/install-templates.sh"

	if ! in_path byobu ; then
		run_apt update
		banner "Install byobu packages"
		run_apt install byobu
	fi
	if ! in_path byobu ; then
		error "byobu not found"
	fi

	if byobu list-session 2>&1 | grep -E -q -e "^no server|^error connecting" ; then
		byobu new-session -d -n 'install-proxmox' "$0 --run; bash"

		if [[ -f $GETISOS ]] ; then
			byobu new-window -t 1 -n 'get-isos' "$GETISOS"
		fi

		if [[ -f $GETMPLS ]] ; then
			byobu new-window -t 2 -n 'get-templates' "$GETMPLS --download-only"
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
		-n|--dry-run|--test) TEST="echo";;
		--trace) TRACE=y; set -x;;
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
