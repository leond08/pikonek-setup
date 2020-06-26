#!/bin/bash

# Installation of PiKonek
#
#

set -e 
set -u

PIKONEK_VERSION="2020.06.1"
NODE_VERSION="setup_12.x"
NODE_URL="https://deb.nodesource.com/${NODE_VERSION}"
PIKONEK_IPADDRESS="10.0.0.1"
SUBNETMASK="255.255.255.0"
IPRANGE_START="10.0.0.100"
IPRANGE_END="10.0.0.200"
WAN_DHCP_ENABLED="dhcp"
WAN_SUBNETMASK=""
WAN_INTERFACE="eth0"
LAN_AP_INTERFACE="eth1"
LAN_AP_IPADDRESS="10.0.0.1"
LAN_AP_SUBNET="255.255.255.0"
WLAN_AP_INTERFACE="wlan0"
WLAN_AP_IPADDRESS="10.0.0.1"
WLAN_AP_SUBNET="255.255.255.0"
WLAN_AP_ENABLED="no"
# IP_SUBNET_CMD="ipcalc -c 10.0.0.255 | awk 'FNR == 2 {print $2} '"

function install_package()
{
	echo -e "[.] Installing package ${1}..."
	# Check if our package is installed
	if dpkg-query -W -f='${Status}' "${1}" 2>/dev/null | grep -q "ok installed" >/dev/null 2>&1
	then
		echo -e "[/] Package already installed."
	else
	apt-get -y --no-install-recommends install $1
		if [ $? != 0 ]; then echo -e "[x] Failed to install" && return 1; else echo -e "[/] Package installed successfully" && return 0; fi
	fi
}

function verify_action()
{
	code=$?
	if [ $code != 0 ]; then echo -e "[.] Exiting build with return code ${code}" && exit 1; fi
}

function update_sources()
{
	echo -e "[.] Updating sources..."
	sudo apt-get update > /dev/null 2>&1
	if [ $? != 0 ]; then echo -e "[x] Failed to update sources" && return 1; else echo -e "[/] Sources updated successfully" && return 0; fi
}

function hostapd_conf() {
    # Backup old configuration
    cp /etc/hostapd.conf /etc/hostapd.conf.old
    ( \
        echo "interface=${WLAN_AP_INTERFACE}"; \
        echo "ssid=PiKonek"; \
        echo "hw_mode=g"; \
        echo "channel=6"; \
        echo "macaddr_acl=0";
        echo "auth_algs=1"; \
        echo "ignore_broadcast_ssid=0"; \
        echo "wpa=2"; \
        echo "wpa_passphrase=pikonek"; \
        echo "wpa_key_mgmt=WPA-PSK"; \
        echo "wpa_pairwise=TKIP"; \
        echo "rsn_pairwise=CCMP"; \
    ) > /etc/hostapd.conf
}

function network_interfaces() {
    # Backup old config
    echo -e "[.] Setting up network interfaces..."
    cp /etc/network/interfaces /etc/network/interfaces.old
    local WAN_CONFIG
    local LAN_AP_CONFIG

    if [ "$WAN_DHCP_ENABLED" == "dhcp" ];
    then
        WAN_CONFIG="auto ${WAN_INTERFACE} \n
        iface ${WAN_INTERFACE} inet dhcp \n
        "
    else
        WAN_CONFIG="auto ${WAN_INTERFACE} \n
        iface ${WAN_INTERFACE} inet static \n
        address ${WAN_IP_ADDRESS} \n
        netmask ${WAN_SUBNETMASK} \n
        "
    fi

    LAN_AP_CONFIG="auto ${LAN_AP_INTERFACE} \n
    iface ${LAN_AP_INTERFACE} inet static \n
    address ${LAN_AP_IPADDRESS} \n
    netmask ${LAN_AP_SUBNET} \n
    "

    ( \
        echo -e $WAN_CONFIG; \
        echo -e $LAN_AP_CONFIG; \
    ) > /etc/network/interfaces.d/pikonek
    verify_action
    echo -e "[/] Done."
}

function systctl_conf() {
    echo -e "[.] Setting up sysctl configuration..."
    # Check if there is /etc/sysctl.conf
    if [ -e /etc/sysctl.conf ];
    then
        # Check if there is a match
        grep -qE '#net.ipv4.ip_forward=1' /etc/sysctl.conf
        if [ $? == 0  ]; then
        sed -i '/#net.ipv4.ip_forward=1/a\
        net.ipv4.ip_forward=1' /etc/sysctl.conf
        fi
    else
        ( \
            echo "net.ipv4.ip_forward=1"; \
        ) > /etc/sysctl.conf
    fi
    verify_action
    echo -e "[/] Done."
}

function dnsmasq_config() {
    # Back up configuration
    echo -e "[.] Setting up dnsmasq configuration..."
    cp /etc/dnsmasq.conf /etc/dnsmasq.conf.old
    # Configuration
    ( \
        echo "domain-needed"; \
        echo "bogus-priv"; \
        echo "domain=portal.pikonek"; \
        # echo "dhcp-range=${LAN_AP_INTERFACE},${IPRANGE_START},${IPRANGE_END},${LAN_AP_SUBNET},24h"; \
        # echo "dhcp-option=3,${LAN_AP_IPADDRESS}"; \
        echo "dhcp-option=3";
        # echo "interface=${LAN_AP_INTERFACE}"; \ # Add multiple interfaces
        echo "#addn-hosts=/etc/pikonek.list"; \
        echo "#no-hosts"; \
        echo "#no-resolv"; \
        echo "#conf-file=/etc/blocked/domains"; \
        echo "#addn-hosts=/etc/blocked/adware"; \
        echo "#addn-hosts=/etc/blocked/pisokonekblockedlist"; \
        echo "#addn-hosts=/etc/blocked/porn"; \
        echo "#addn-hosts=/etc/blocked/social"; \
        echo "#addn-hosts=/etc/blocked/gambling"; \
        echo "#addn-hosts=/etc/blocked/fakenews"; \
        # echo "#resolv-file=/etc/pikonek.resolv"; \                                                            
        echo "server=8.8.8.8"; \
        echo "except-interface=lo"; \
        echo "dhcp-authoritative"; \
    ) > /etc/dnsmasq.conf
    verify_action
    echo -e "[/] Done."
}

function valid_ip() {
    ipcalc -cn ${1} | grep "INVALID" && return 1 || return 0
}

function setup_wan_network_interface() {
    # Set up wan interface
    echo -e "[.] Configure WAN interface"
    PS3="Enter the number of your WAN interface: "
    select INTERFACES in $(ip link | awk -F: '$0 !~ "lo|vir|wl|^[^0-9]"{print $2;getline}');
    do
        case $INTERFACES in
            *)  
                if [[ ! -z "$INTERFACES" ]]
                then
                    WAN_INTERFACE=$INTERFACES
                    echo "Configure IPv4 address WAN interface via DHCP? (y/n): "
                    read answer
                    if [[ ! -z "$answer" ]]
                    then
                        if [[ "$answer" == "n" || "$answer" == "no" ]]
                        then
                            while true;
                            do
                                echo "Enter the WAN IPv4 address(ie 192.168.0.1/24): "
                                read TMP_WAN_IP_ADDRESS
                                if valid_ip $TMP_WAN_IP_ADDRESS == 0;
                                then
                                    WAN_DHCP_ENABLED="static"
                                    WAN_IP_ADDRESS=$(echo $TMP_WAN_IP_ADDRESS | cut -d"/" -f1)
                                    # Get subnet mask
                                    WAN_SUBNETMASK=$(ipcalc -cn $TMP_WAN_IP_ADDRESS | awk 'FNR == 2 {print $2}')
                                    echo -e "${WAN_INTERFACE}/WAN" > pikonek_interface
                                    return 0
                                fi
                            done
                        fi
                        echo -e "${WAN_INTERFACE}/WAN" > pikonek_interface
                        return 0
                    else
                        echo -e "${WAN_INTERFACE}/WAN" > pikonek_interface
                        break
                    fi
                    echo -e "${WAN_INTERFACE}/WAN" > pikonek_interface
                fi
                ;;
        esac
    done
}

function setup_lan_network_interface() {
    echo -e "[.] Configure LAN interface"
    PS3="Enter the number of your LAN interface: (Or press any to set the default LAN(eth1)): "
    select INTERFACES in $(ip link | awk -F: '$0 !~ "lo|vir|wl|^[^0-9]"{print $2;getline}');
    do
        case $INTERFACES in
            *)  
                if [[ ! -z "$INTERFACES" ]]
                then
                    interface=$(cat pikonek_interface | cut -d"/" -f1)
                    if [ "$INTERFACES" != "$interface" ]
                    then
                        LAN_AP_INTERFACE=$INTERFACES
                    fi
                else
                 LAN_AP_INTERFACE="eth1"
                fi
                while true;
                do
                    echo "Enter the LAN IPv4 address(ie 10.0.0.1/24): "
                    read TMP_LAN_IP_ADDRESS
                    if valid_ip $TMP_LAN_IP_ADDRESS == 0;
                    then
                        LAN_AP_IPADDRESS=$(echo $TMP_LAN_IP_ADDRESS | cut -d"/" -f1)
                        # Get subnet mask
                        LAN_AP_SUBNET=$(ipcalc -cn $TMP_LAN_IP_ADDRESS | awk 'FNR == 2 {print $2}')
                        return 0
                    fi
                done
                ;;
        esac
    done
}

function setup_wireless_interface() {
    local WLAN_AP_CONFIG
    echo -e "[.] Configure wireless access point"
    echo -e "Enable wireless access point? (y|n): "
    read wi_answer
    while true;
    do
        case $wi_answer in
            y)
                WLAN_AP_CONFIG="auto ${WLAN_AP_INTERFACE} \n
                iface ${WLAN_AP_INTERFACE} inet static \n
                address ${LAN_AP_IPADDRESS} \n
                netmask ${LAN_AP_SUBNET} \n
                pre-up hostapd /etc/hostapd.conf -B \n
                post-down killall -q hostapd"
                WLAN_AP_ENABLED="yes"
                break
                ;;
            n) 
                WLAN_AP_CONFIG="auto ${WLAN_AP_INTERFACE} \n
                iface ${WLAN_AP_INTERFACE} inet dhcp \n
                "
                break
                ;;
        esac
    done

    ( \
        echo -e $WLAN_AP_CONFIG; \
    ) >> /etc/network/interfaces.d/pikonek
}

function setup_dhcp_dns() {
    # Set up dns and dhcp
    # Select interfaces to listen
    echo -e "[.] Setting up dhcp..."
    dnsmasq_config
    echo -e "Provide dhcp range. (ie x.x.x.100,x.x.x.200): "
    read dhcp_range
    if [ ! -z "$LAN_AP_INTERFACE" ]
    then

        range1=$(echo "$dhcp_range" | cut -d"," -f1)
        range2=$(echo "$dhcp_range" | cut -d"," -f2)

        if valid_ip $range1 == 0 && valid_ip $range2 == 0;
        then
            ( \
                echo -e "dhcp-range=${LAN_AP_INTERFACE},${range1},${range2},${LAN_AP_SUBNET},24h"; \
                echo -e "interface=${LAN_AP_INTERFACE}"; \
            ) >> /etc/dnsmasq.conf
            if [ "$WLAN_AP_ENABLED" == "yes" ]
            then
                ( \ 
                    echo -e "dhcp-range=${WLAN_AP_INTERFACE},${range1},${range2},${LAN_AP_SUBNET},24h"; \
                    echo -e "interface=${WLAN_AP_INTERFACE}"; \
                ) >> /etc/dnsmasq.conf
            fi
        else
            setup_dhcp_dns
        fi
    fi
}


echo -e "[.] Building target side installer"

packages="apache2
hostapd
sqlite3
ipcalc
dnsmasq
virtualenv
nodejs
gawk
"

# Add nodejs repository 
# echo -e "[.] Adding nodejs repository ${NODE_URL}..."
# curl -sL ${NODE_URL} | sudo bash -
# verify_action

# update_sources
# verify_action

# We install the packages
# echo -e "[.] Installing packages..."
# for package in $packages
# do
# 	install_package $package
# 	verify_action
# done

setup_wan_network_interface
setup_lan_network_interface
network_interfaces
setup_wireless_interface
setup_dhcp_dns

