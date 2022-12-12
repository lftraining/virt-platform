#!/bin/bash
##############################################################################
# Written by: Behan Webster
# Licensed under the GPLv2
#
# Install proxmox on new Debian install
#

set -e

VERSION=1.0

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
PVEUM="verbose pveum"
RM="verbose rm -f"
SED="verbose sed"
WGET="verbose wget --continue --quiet --show-progress --progress=bar"

SOURCESD="/etc/apt/sources.list.d"
ENTERPRISE="$SOURCESD/pve-enterprise.list"
PVELIST="$SOURCESD/pve-install-repo.list"

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
	echo -e "${YELLOW}W:" "$@" "$BACK" >&2
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
	USERID="student"
	PASSWORD="$(get_password)"
	NFS="/srv/LFT"
}

##############################################################################
read_config() {
	default_config
	
	banner "Read Configuration"

	local CONF FILES="$HOME/.config/install-proxmox/defaults.conf $HOME/.install-proxmox.conf"	
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
	curl -sSL https://repos.insights.digitalocean.com/install.sh | sudo bash
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
update_hosts() {
	local FQDN="$1" IP
	IP="$(get_ip)"
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
		#if [[ $FQDN != "$HOSTNAME" ]] ; then
		#	ENTRY+=" $FQDN"
		#	$SED -iE "s/(${IP//./\\.}.*)$FQDN/\$1/" "$HOSTS"
		#fi
		#$SED -iE "s/(${IP//./\\.}.*)$HOSTNAME/\$1/" "$HOSTS"
		#$SED -iE "s/${IP//./\\.}[ 	]*/$ENTRY /" "$HOSTS"
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
generate_name() {
	grep -E '^[a-z]{5,8}$' /usr/share/dict/words | grep -Ev '[^e]ed$|.{2,}(i)*est$|.{2,}(i)*er$|ily$|.{2,}ish$|.{2,}ing$|ly$|s$|ty$|abort|abuse|adult|alcohol|devil|flesh' | shuf -n 1 -
}

##############################################################################
new_hostname() {
	banner "New Hostname"
	local HOST FQDN
	run_apt install wamerican
	while true ; do
		HOST="$(generate_name)"
		FQDN="$HOST.$DOMAIN"
		info "Trying $FQDN"
		if host "$FQDN" | grep -q "not found" ; then
			info "$FQDN available"
			verbose hostnamectl set-hostname "$HOST"
			update_hosts "$FQDN"
			HOSTNAME="$HOST"
			return
		fi
	done
}

##############################################################################
update_hostname() {
	banner "Update Hostname"
	local IP
	IP="$(get_ip)"

	if grep -q "^$IP.*$DOMAIN" "$HOSTS" ; then
		warn "$HOSTNAME already set to $IP"
	else
		new_hostname
	fi
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
	elif grep -q "^root:.:" /etc/shadow ; then
		info "Set root password"
		if [[ -z $TEST ]] ; then
			chpasswd <<<"root:$PASSWORD"
		else
			verbose "chpasswd <<<root:$PASSWORD"
		fi
	else
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
update_debian() {
	banner "Update Debian packages"
	$RM "$ENTERPRISE"
	run_apt update
	run_apt full-upgrade
}

##############################################################################
install_debian_extras() {
	if dpkg --get-selections postfix | grep -q install ; then
		warn "Postfix already installed"
	else
		banner "Install Postfix"
		verbose debconf-set-selections <<< "postfix postfix/mailname string $HOSTNAME"
		verbose debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Local only'"
		run_apt install postfix
		$RM debconf-set-selections
	fi

	banner "Install extra Debian packages"
	run_apt install chrony etckeeper ksmtuned lsof mosh needrestart nfs-kernel-server rsync ssh sudo unattended-upgrades vim vim-youcompleteme

	verbose vim-addons install youcompleteme

	banner "Install Debian kernel packages"
	run_apt install bc bison build-essential flex libelf-dev libssl-dev lz4

	#banner "Remove uneeded Debian packages"
	#run_apt purge reportbug python3-debian python3-debianbts python3-httplib2 python3-pycurl python3-pysimplesoap python3-reportbug
}

##############################################################################
setup_debian() {
	update_debian
	install_debian_extras
}

##############################################################################
install_proxmox() {
	banner "Install Proxmox packages"
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
		run_apt update
	fi
	run_apt install proxmox-ve
	$RM "$ENTERPRISE"
}

##############################################################################
setup_proxmox_users() {
	local USER="$USERID@pve" GROUP="admin"
	banner "Setup Proxmox users"
	set +e
	$PVEUM group add "$GROUP" -comment "System Administrators" || true
	$PVEUM acl modify / -group "$GROUP" -role Administrator
	$PVEUM user del "$USER"
	$PVEUM user add "$USER" --password "$PASSWORD" --firstname "Linux" --lastname "Learner"
	$PVEUM user modify "$USER" -group admin
	$PVEUM pool add services --comment "Services Pool"
	set -e
}

##############################################################################
setup_proxmox() {
	install_proxmox
	setup_proxmox_users
}

##############################################################################
setup_bridge() {
	local BRIDGE="vmbr0"
	local IFACE="eth0"
	local INTERFACES="/etc/network/interfaces"

	banner "Setup Bridge:$BRIDGE"
	if grep -q "iface $BRIDGE inet" "$INTERFACES" ; then
		warn "Network already configured: $BRIDGE"
	elif [[ -z $TEST ]] ; then
		info "Adding $BRIDGE to $INTERFACES"
		cat <<END >>"$INTERFACES"

auto $BRIDGE
iface $BRIDGE inet static
	address $NETWORK.1/$NETMASK
	bridge-ports none
	bridge-stp off
	bridge-fd 0
        post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
        post-up   iptables -t nat -A POSTROUTING -s '$NETWORK.0/$NETMASK' -o $IFACE -j MASQUERADE
	post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
        post-down iptables -t nat -D POSTROUTING -s '$NETWORK.0/$NETMASK' -o $IFACE -j MASQUERADE
	post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
END
	fi
	chmod 644 "$INTERFACES"

	info "Bring up $BRIDGE"
	verbose ifup $BRIDGE
}

##############################################################################
setup_firewall() {
	local FW="/etc/pve/firewall/cluster.fw"
	banner "Setup Cluster Firewall"
	if [[ -e "$FW" ]] ; then
		warn "Cluster Firewall already configured: $FW"
	elif [[ -z $TEST ]] ; then
		info "Install Cluster Firewall"
		$MKDIR "${FW%/*}"
		cat <<END >"$FW"
[OPTIONS]

enable: 1

[RULES]

GROUP ssh
GROUP proxmox -i eth0
GROUP web

[group proxmox] # Proxmox GUI

IN ACCEPT -p tcp -dport 8006 -log nolog # Proxmox web GUI
IN VNC(ACCEPT) -log nolog # VNC port
IN ACCEPT -p tcp -dport 3128 -log nolog # Spice Proxy for remote terminals

[group ssh] # Remote access

IN SSH(ACCEPT) -log nolog # SSH on normal port
IN ACCEPT -p udp -dport 60000:60010 -log nolog # Mosh access

[group web] # Web ports

IN HTTP(ACCEPT) -log nolog
IN HTTPS(ACCEPT) -log nolog

END
	fi
	chown -R root:www-data "${FW%/*}"

	local FW="/etc/pve/local/host.fw"
	banner "Setup Host Firewall"
	if [[ -e "$FW" ]] ; then
		warn "Host Firewall already configured: $FW"
	elif [[ -z $TEST ]] ; then
		info "Install Host Firewall"
		cat <<END >"$FW"
[RULES]

IN ACCEPT -i vmbr0 -p tcp -dport 111,2049 -log nolog # NFS
END
	fi

	chown -R root:www-data "${FW%/*}"

	if pve-firewall compile >/dev/null ; then
		info "Restart Firewall"
		verbose pve-firewall restart
	else
		error "Firewall rules failed"
	fi
}

##############################################################################
setup_nfs() {
	local EXPORTS="/etc/exports"
	banner "Setup NFS"
	if grep -q "^$NFS" "$EXPORTS" ; then
		warn "NFS Export already added."
	elif [[ -z $TEST ]] ; then
		cat <<END >>"$EXPORTS"
$NFS	$NETWORK.0/$NETMASK(rw,sync,no_subtree_check,no_root_squash)
END
	fi

	info "Exportfs NFS"
	$MKDIR "$NFS"
	verbose chmod 2777 "$NFS"
	verbose exportfs -a
	verbose showmount -e
}

##############################################################################
setup_network() {
	setup_bridge
	setup_firewall
}

##############################################################################
update_dyndns() {
	banner "Update DynDNS:"
	# TODO
}

##############################################################################
update_letsencrypt() {
	banner "Update Letsencrypt"
	# TODO
}

##############################################################################
setup_dns() {
	update_dyndns
	update_letsencrypt
}

##############################################################################
check_kernel_version() {
	local KVER
	KVER="$(uname -r | sed -E -e 's/^([0-9]+\.[0-9]+)\..*$/\1/')"

	if [[ $KVER != 5.15 ]] ; then
		warn "You need to reboot before continuing"
		info "Once you reboot, run install-templates.sh"
		exit 0
	fi
}

##############################################################################
welcome() {
	banner "visit https://$(get_ip):8006/ in your browser"
	info "Login as root, password $PASSWORD, and Realm set to 'Linux PAM standard authentication'"
}

##############################################################################
do_the_thing() {
	install_digitalocean_extras
	update_hostname
	setup_ssh_root
	setup_debian
	setup_proxmox
	setup_network
	#setup_dns
	welcome
	check_kernel_version
}

##############################################################################
run_thing_in_byobu() {
	if ! in_path byobu ; then
		run_apt update
		banner "Install byobu packages"
		run_apt install byobu
	fi
	if ! in_path byobu ; then
		error "byobu not found"
	fi
	byobu new-window "$0 --run && bash"
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
