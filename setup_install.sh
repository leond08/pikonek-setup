#!/usr/bin/env bash
# shellcheck disable=SC1090

# PiKonek: A black hole for Internet advertisements
# (c) 2020 PiKonek
# Pisowifi and Firewall Management
#
# Installs and Updates PiKonek
#
# -e option instructs bash to immediately exit if any command [1] has a non-zero exit status
# We do not want users to end up with a partially working install, so we exit the script
# instead of continuing the installation with something broken
set -e

######## VARIABLES #########
# For better maintainability, we store as much information that can change in variables
# This allows us to make a change in one place that can propagate to all instances of the variable
# These variables should all be GLOBAL variables, written in CAPS
# Local variables will be in lowercase and will exist only within functions
# It's still a work in progress, so you may see some variance in this guideline until it is complete

# List of supported DNS servers
DNS_SERVERS=$(cat << EOM
Google (ECS);8.8.8.8;8.8.4.4;2001:4860:4860:0:0:0:0:8888;2001:4860:4860:0:0:0:0:8844
OpenDNS (ECS);208.67.222.222;208.67.220.220;2620:119:35::35;2620:119:53::53
Level3;4.2.2.1;4.2.2.2;;
Comodo;8.26.56.26;8.20.247.20;;
DNS.WATCH;84.200.69.80;84.200.70.40;2001:1608:10:25:0:0:1c04:b12f;2001:1608:10:25:0:0:9249:d69b
Quad9 (filtered, DNSSEC);9.9.9.9;149.112.112.112;2620:fe::fe;2620:fe::9
Quad9 (unfiltered, no DNSSEC);9.9.9.10;149.112.112.10;2620:fe::10;2620:fe::fe:10
Quad9 (filtered + ECS);9.9.9.11;149.112.112.11;2620:fe::11;
Cloudflare;1.1.1.1;1.0.0.1;2606:4700:4700::1111;2606:4700:4700::1001
EOM
)

# Location for final installation log storage
installLogLoc=/etc/pikonek/install.log
# This is an important file as it contains information specific to the machine it's being installed on
setupVars=/etc/pikonek/setupVars.conf
# PiKonek uses lighttpd as a Web server, and this is the config file for it
# shellcheck disable=SC2034
webroot="/var/www/html"
pikonekGitUrl="https://github.com/leond08/pikonek.git"
pikonekGitConfig="https://github.com/leond08/configs.git"
pikonekGitScripts="https://github.com/leond08/scripts.git"
pikonekGitPackages="https://github.com/leond08/packages.git"
pikonekGitBlockedList="https://github.com/leond08/blocked.git"
PIKONEK_LOCAL_REPO="/etc/.pikonek"
# This directory is where the PiKonek scripts will be installed
PIKONEK_INSTALL_DIR="/etc/pikonek"
PIKONEK_BIN_DIR="/usr/local/bin"
useUpdateVars=false

# PiKonek needs an IP address; to begin, these variables are empty since we don't know what the IP is until
# this script can run
IPV4_ADDRESS=${IPV4_ADDRESS}
IPV6_ADDRESS=${IPV6_ADDRESS}
# By default, query logging is enabled and the dashboard is set to be installed
QUERY_LOGGING=true
INSTALL_WEB_INTERFACE=true
PRIVACY_LEVEL=0
LIGHTTPD_USER="www-data"
LIGHTTPD_GROUP="www-data"
# and config file
LIGHTTPD_CFG="lighttpd.conf"

if [ -z "${USER}" ]; then
  USER="$(id -un)"
fi

is_pi () {
  ARCH=$(dpkg --print-architecture)
  if [ "$ARCH" = "armhf" ] || [ "$ARCH" = "arm64" ] ; then
    return 0
  else
    return 1
  fi
}

if is_pi ; then
  CMDLINE=/boot/cmdline.txt
else
  CMDLINE=/proc/cmdline
fi


# Check if we are running on a real terminal and find the rows and columns
# If there is no real terminal, we will default to 80x24
if [ -t 0 ] ; then
  screen_size=$(stty size)
else
  screen_size="24 80"
fi
# Set rows variable to contain first number
printf -v rows '%d' "${screen_size%% *}"
# Set columns variable to contain second number
printf -v columns '%d' "${screen_size##* }"

# Divide by two so the dialogs take up half of the screen, which looks nice.
r=$(( rows / 2 ))
c=$(( columns / 2 ))
# Unless the screen is tiny
r=$(( r < 20 ? 20 : r ))
c=$(( c < 70 ? 70 : c ))

######## Undocumented Flags. Shhh ########
# These are undocumented flags; some of which we can use when repairing an installation
# The runUnattended flag is one example of this
skipSpaceCheck=false
reconfigure=false
runUnattended=false
INSTALL_WEB_SERVER=true
# Check arguments for the undocumented flags
for var in "$@"; do
    case "$var" in
        "--reconfigure" ) reconfigure=true;;
    esac
done

# Set these values so the installer can still run in color
COL_NC='\e[0m' # No Color
COL_LIGHT_GREEN='\e[1;32m'
COL_LIGHT_RED='\e[1;31m'
TICK="[${COL_LIGHT_GREEN}✓${COL_NC}]"
CROSS="[${COL_LIGHT_RED}✗${COL_NC}]"
INFO="[i]"
# shellcheck disable=SC2034
DONE="${COL_LIGHT_GREEN} done!${COL_NC}"
OVER="\\r\\033[K"

# A simple function that just echoes out our logo in ASCII format
show_ascii_berry() {
    echo -e "
    ${COL_LIGHT_RED}         ____  _ _  __                _    
            |  _ \(_) |/ /___  _ __   ___| | __
            | |_) | | ' // _ \| '_ \ / _ \ |/ /
            |  __/| | . \ (_) | | | |  __/   < 
            |_|   |_|_|\_\___/|_| |_|\___|_|\_\.${COL_NC}
    "
}

uninstall() {
    # Remove existing files
    rm -rf "${PIKONEK_INSTALL_DIR}/configs"
    rm -rf "${PIKONEK_INSTALL_DIR}/scripts"
    rm -rf "${PIKONEK_INSTALL_DIR}/pikonek"
    rm -rf "${PIKONEK_INSTALL_DIR}/packages"
    rm -rf "${PIKONEK_INSTALL_DIR}/setupVars.conf"
    rm -rf "${PIKONEK_INSTALL_DIR}/setupVars.conf.update.bak"
    rm -rf "${PIKONEK_INSTALL_DIR}/install.log"
    rm -rf "${PIKONEK_INSTALL_DIR}/blocked"
    rm -rf "${PIKONEK_INSTALL_DIR}"
    rm -rf /etc/logrotate.d/pikonek
    rm -rf /etc/dnsmasq.d/01-pikonek.conf
    rm -rf /etc/init.d/S70piknkmain
    rm -rf /etc/init.d/S70pikonekcaptive
    rm -rf /etc/init.d/S70pikonekcaptivefw
    rm -rf /etc/sudoers.d/pikonek
    rm -rf /usr/local/bin/pikonek
    rm -rf /etc/cron.d/pikonek
    rm -rf /etc/cron.daily/pikonekupdateblockedlist
}

is_command() {
    # Checks for existence of string passed in as only function argument.
    # Exit value of 0 when exists, 1 if not exists. Value is the result
    # of the `command` shell built-in call.
    local check_command="$1"

    command -v "${check_command}" >/dev/null 2>&1
}

os_check() {
    # This function gets a list of supported OS versions from a TXT record at versions.PiKonek.net
    # and determines whether or not the script is running on one of those systems
    local remote_os_domain valid_os valid_version detected_os_pretty detected_os detected_version display_warning
    remote_os_domain="Raspbian=10 Ubuntu=18,20"
    valid_os=false
    valid_version=false
    display_warning=true

    detected_os_pretty=$(cat /etc/*release | grep PRETTY_NAME | cut -d '=' -f2- | tr -d '"')
    detected_os="${detected_os_pretty%% *}"
    detected_version=$(cat /etc/*release | grep VERSION_ID | cut -d '=' -f2- | tr -d '"')

    IFS=" " read -r -a supportedOS < <(echo ${remote_os_domain} | tr -d '"')

    for i in "${supportedOS[@]}"
    do
        os_part=$(echo "$i" | cut -d '=' -f1)
        versions_part=$(echo "$i" | cut -d '=' -f2-)

        if [[ "${detected_os}" =~ ${os_part} ]]; then
          valid_os=true
          IFS="," read -r -a supportedVer <<<"${versions_part}"
          for x in "${supportedVer[@]}"
          do
            if [[ "${detected_version}" =~ $x ]];then
              valid_version=true
              break
            fi
          done
          break
        fi
    done

    if [ "$valid_os" = true ] && [ "$valid_version" = true ]; then
        display_warning=false
    fi

    if [ "$display_warning" = true ] && [ "$pikonek_SKIP_OS_CHECK" != true ]; then
        printf "  %b %bUnsupported OS detected%b\\n" "${CROSS}" "${COL_LIGHT_RED}" "${COL_NC}"
        printf "      https://docs.PiKonek.net/main/prerequesites/#supported-operating-systems\\n"
        printf "\\n"
        exit 1
    else
        printf "  %b %bSupported OS detected%b\\n" "${TICK}" "${COL_LIGHT_GREEN}" "${COL_NC}"
    fi
}

# Compatibility
distro_check() {
# If apt-get is installed, then we know it's part of the Debian family
if is_command apt-get ; then
    # Set some global variables here
    # We don't set them earlier since the family might be Red Hat, so these values would be different
    PKG_MANAGER="apt-get"
    # A variable to store the command used to update the package cache
    UPDATE_PKG_CACHE="${PKG_MANAGER} update"
    # An array for something...
    PKG_INSTALL=("${PKG_MANAGER}" -qq --no-install-recommends install)
    # grep -c will return 1 retVal on 0 matches, block this throwing the set -e with an OR TRUE
    PKG_COUNT="${PKG_MANAGER} -s -o Debug::NoLocking=true upgrade | grep -c ^Inst || true"
    # Some distros vary slightly so these fixes for dependencies may apply
    # on Ubuntu 18.04.1 LTS we need to add the universe repository to gain access to dhcpcd5
    APT_SOURCES="/etc/apt/sources.list"
    if awk 'BEGIN{a=1;b=0}/bionic main/{a=0}/bionic.*universe/{b=1}END{exit a + b}' ${APT_SOURCES}; then
        if ! whiptail --defaultno --title "Dependencies Require Update to Allowed Repositories" --yesno "Would you like to enable 'universe' repository?\\n\\nThis repository is required by the following packages:\\n\\n- dhcpcd5" "${r}" "${c}"; then
            printf "  %b Aborting installation: Dependencies could not be installed.\\n" "${CROSS}"
            exit 1 # exit the installer
        else
            printf "  %b Enabling universe package repository for Ubuntu Bionic\\n" "${INFO}"
            cp -p ${APT_SOURCES} ${APT_SOURCES}.backup # Backup current repo list
            printf "  %b Backed up current configuration to %s\\n" "${TICK}" "${APT_SOURCES}.backup"
            add-apt-repository universe
            printf "  %b Enabled %s\\n" "${TICK}" "'universe' repository"
        fi
    fi
    # Update package cache. This is required already here to assure apt-cache calls have package lists available.
    update_package_cache || exit 1
    # Debian 7 doesn't have iproute2 so check if it's available first
    if apt-cache show iproute2 > /dev/null 2>&1; then
        iproute_pkg="iproute2"
    # Otherwise, check if iproute is available
    elif apt-cache show iproute > /dev/null 2>&1; then
        iproute_pkg="iproute"
    # Else print error and exit
    else
        printf "  %b Aborting installation: iproute2 and iproute packages were not found in APT repository.\\n" "${CROSS}"
        exit 1
    fi
    # Check for and determine version number (major and minor) of current python install
    if is_command python3 ; then
        printf "  %b Existing python3 installation detected\\n" "${INFO}"
        pythonNewer=true
    fi
    # Check if installed python3 or newer to determine packages to install
    if [[ "$pythonNewer" != true ]]; then
        # Prefer the python3 metapackage if it's there
        if apt-cache show python3 > /dev/null 2>&1; then
            python3Ver="python3"
        # Else print error and exit
        else
            printf "  %b Aborting installation: No Python3 packages were found in APT repository.\\n" "${CROSS}"
            exit 1
        fi
    else
        python3Ver="python3"
    fi
    # We also need the correct version for `python3-pip` (which differs across distros)
    if apt-cache show "${python3Ver}-pip" > /dev/null 2>&1; then
        pythonpip3="python3-pip"
    else
        printf "  %b Aborting installation: No python3-pip module was found in APT repository.\\n" "${CROSS}"
        exit 1
    fi
    # Since our install script is so large, we need several other programs to successfully get a machine provisioned
    # These programs are stored in an array so they can be looped through later
    INSTALLER_DEPS=(ipcalc lighttpd python3 sqlite3 dnsmasq python3-pip python3-apt gawk curl cron wget iptables iptables-persistent iptables-save whiptail git openssl ifupdown ntp wpasupplicant)
    # The Web server user,
    LIGHTTPD_USER="www-data"
    # group,
    LIGHTTPD_GROUP="www-data"
    # and config file
    LIGHTTPD_CFG="lighttpd.conf"

    # A function to check...
    test_dpkg_lock() {
        # An iterator used for counting loop iterations
        i=0
        # fuser is a program to show which processes use the named files, sockets, or filesystems
        # So while the command is true
        while fuser /var/lib/dpkg/lock >/dev/null 2>&1 ; do
            # Wait half a second
            sleep 0.5
            # and increase the iterator
            ((i=i+1))
        done
        # Always return success, since we only return if there is no
        # lock (anymore)
        return 0
    }

# If apt-get is not found, check for rpm to see if it's a Red Hat family OS
# If neither apt-get
else
    # it's not an OS we can support,
    printf "  %b OS distribution not supported\\n" "${CROSS}"
    # so exit the installer
    exit
fi
}

# A function for checking if a directory is a git repository
is_repo() {
    # Use a named, local variable instead of the vague $1, which is the first argument passed to this function
    # These local variables should always be lowercase
    local directory="${1}"
    # A variable to store the return code
    local rc
    # If the first argument passed to this function is a directory,
    if [[ -d "${directory}" ]]; then
        # move into the directory
        pushd "${directory}" &> /dev/null || return 1
        # Use git to check if the directory is a repo
        # git -C is not used here to support git versions older than 1.8.4
        git status --short &> /dev/null || rc=$?
    # If the command was not successful,
    else
        # Set a non-zero return code if directory does not exist
        rc=1
    fi
    # Move back into the directory the user started in
    popd &> /dev/null || return 1
    # Return the code; if one is not set, return 0
    return "${rc:-0}"
}

# A function to clone a repo
make_repo() {
    # Set named variables for better readability
    local directory="${1}"
    local remoteRepo="${2}"

    # The message to display when this function is running
    str="Clone ${remoteRepo} into ${directory}"
    # Display the message and use the color table to preface the message with an "info" indicator
    printf "  %b %s..." "${INFO}" "${str}"
    # If the directory exists,
    if [[ -d "${directory}" ]]; then
        # delete everything in it so git can clone into it
        rm -rf "${directory}"
    fi
    # Clone the repo and return the return code from this command
    git clone -q --depth 20 "${remoteRepo}" "${directory}" &> /dev/null || return $?
    # Move into the directory that was passed as an argument
    pushd "${directory}" &> /dev/null || return 1
    # Data in the repositories is public anyway so we can make it readable by everyone (+r to keep executable permission if already set by git)
    chmod -R a+rX "${directory}"
    # Move back into the original directory
    popd &> /dev/null || return 1
    return 0
}

# We need to make sure the repos are up-to-date so we can effectively install Clean out the directory if it exists for git to clone into
update_repo() {
    # Use named, local variables
    # As you can see, these are the same variable names used in the last function,
    # but since they are local, their scope does not go beyond this function
    # This helps prevent the wrong value from being assigned if you were to set the variable as a GLOBAL one
    local directory="${1}"
    local curBranch

    # A variable to store the message we want to display;
    # Again, it's useful to store these in variables in case we need to reuse or change the message;
    # we only need to make one change here
    local str="Update repo in ${1}"
    # Move into the directory that was passed as an argument
    pushd "${directory}" &> /dev/null || return 1
    # Let the user know what's happening
    printf "  %b %s..." "${INFO}" "${str}"
    # Stash any local commits as they conflict with our working code
    git stash --all --quiet &> /dev/null || true # Okay for stash failure
    git clean --quiet --force -d || true # Okay for already clean directory
    # Pull the latest commits
    git pull --quiet &> /dev/null || return $?
    # Check current branch. If it is master, then reset to the latest available tag.
    # In case extra commits have been added after tagging/release (i.e in case of metadata updates/README.MD tweaks)
    # curBranch=$(git rev-parse --abbrev-ref HEAD)
    # if [[ "${curBranch}" == "master" ]]; then
    #      git reset --hard "$(git describe --abbrev=0 --tags)" || return $?
    # fi
    # Show a completion message
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    # Data in the repositories is public anyway so we can make it readable by everyone (+r to keep executable permission if already set by git)
    chmod -R a+rX "${directory}"
    # Move back into the original directory
    popd &> /dev/null || return 1
    return 0
}

# A function that combines the functions previously made
getGitFiles() {
    # Setup named variables for the git repos
    # We need the directory
    local directory="${1}"
    # as well as the repo URL
    local remoteRepo="${2}"
    # A local variable containing the message to be displayed
    local str="Check for existing repository in ${1}"
    # Show the message
    printf "  %b %s..." "${INFO}" "${str}"
    # Check if the directory is a repository
    if is_repo "${directory}"; then
        # Show that we're checking it
        printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
        # Update the repo, returning an error message on failure
        update_repo "${directory}" || { printf "\\n  %b: Could not update local repository. Contact support.%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
    # If it's not a .git repo,
    else
        # Show an error
        printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
        # Attempt to make the repository, showing an error on failure
        make_repo "${directory}" "${remoteRepo}" || { printf "\\n  %bError: Could not create local repository. Contact support.%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
    fi
    # echo a blank line
    echo ""
    # and return success?
    return 0
}

# Reset a repo to get rid of any local changed
resetRepo() {
    # Use named variables for arguments
    local directory="${1}"
    # Move into the directory
    pushd "${directory}" &> /dev/null || return 1
    # Store the message in a variable
    str="Resetting repository within ${1}..."
    # Show the message
    printf "  %b %s..." "${INFO}" "${str}"
    # Use git to remove the local changes
    git reset --hard &> /dev/null || return $?
    # Data in the repositories is public anyway so we can make it readable by everyone (+r to keep executable permission if already set by git)
    chmod -R a+rX "${directory}"
    # And show the status
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    # Return to where we came from
    popd &> /dev/null || return 1
    # Returning success anyway?
    return 0
}

find_IPv4_information() {
    # Detects IPv4 address used for communication to WAN addresses.
    # Accepts no arguments, returns no values.

    # Named, local variables
    local route
    local IPv4bare

    # Find IP used to route to outside world by checking the the route to Google's public DNS server
    route=$(ip route get 8.8.8.8)

    # Get just the interface IPv4 address
    # shellcheck disable=SC2059,SC2086
    # disabled as we intentionally want to split on whitespace and have printf populate
    # the variable with just the first field.
    printf -v IPv4bare "$(printf ${route#*src })"
    # Get the default gateway IPv4 address (the way to reach the Internet)
    # shellcheck disable=SC2059,SC2086
    printf -v IPv4gw "$(printf ${route#*via })"
    printf -v IPv4interface "$(printf ${route#*dev })"

    if ! valid_ip "${IPv4bare}" ; then
        IPv4bare="127.0.0.1"
    fi

    # Append the CIDR notation to the IP address, if valid_ip fails this should return 127.0.0.1/8
    IPV4_ADDRESS=$(ip -oneline -family inet address show | grep "${IPv4bare}/" |  awk '{print $4}' | awk 'END {print}')
}

# Get available interfaces that are UP
get_available_interfaces() {
    # There may be more than one so it's all stored in a variable
    availableInterfaces="$(ip --oneline link show up | grep -v lo | awk '{print $2}' | cut -d':' -f1 | cut -d'@' -f1 | grep eth)"
}

get_available_wlan_interfaces() {
    # There may be more than one so it's all stored in a variable
    availableWlanInterfaces="$(ip --oneline link show up | grep wl | awk '{print $2}' | cut -d':' -f1 | cut -d'@' -f1)"
}

# A function for displaying the dialogs the user sees when first running the installer
welcomeDialogs() {
    # Display the welcome dialog using an appropriately sized window via the calculation conducted earlier in the script
    whiptail --msgbox --backtitle "Welcome" --title "PiKonek automated installer" "\\n\\nWelcome to PiKonek a PisoWifi and Firewall Management!" "${r}" "${c}"

    # Explain the need for a static address
    whiptail --msgbox --backtitle "Welcome" --title "PiKonek automated installer" "\\n\\nThe PiKonek is a SERVER so it needs an internet and STATIC IP ADDRESS to function properly." "${r}" "${c}"
}

# We need to make sure there is enough space before installing, so there is a function to check this
verifyFreeDiskSpace() {
    # 50MB is the minimum space needed (45MB install (includes web admin bootstrap/jquery libraries etc) + 5MB one day of logs.)
    # - Fourdee: Local ensures the variable is only created, and accessible within this function/void. Generally considered a "good" coding practice for non-global variables.
    local str="Disk space check"
    # Required space in KB
    local required_free_kilobytes=51200
    # Calculate existing free space on this machine
    local existing_free_kilobytes
    existing_free_kilobytes=$(df -Pk | grep -m1 '\/$' | awk '{print $4}')

    # If the existing space is not an integer,
    if ! [[ "${existing_free_kilobytes}" =~ ^([0-9])+$ ]]; then
        # show an error that we can't determine the free space
        printf "  %b %s\\n" "${CROSS}" "${str}"
        printf "  %b Unknown free disk space! \\n" "${INFO}"
        printf "      We were unable to determine available free disk space on this system.\\n"
        # exit with an error code
        exit 1
    # If there is insufficient free disk space,
    elif [[ "${existing_free_kilobytes}" -lt "${required_free_kilobytes}" ]]; then
        # show an error message
        printf "  %b %s\\n" "${CROSS}" "${str}"
        printf "  %b Your system disk appears to only have %s KB free\\n" "${INFO}" "${existing_free_kilobytes}"
        printf "      It is recommended to have a minimum of %s KB to run the PiKonek\\n" "${required_free_kilobytes}"
        # if the vcgencmd command exists,
        if is_command vcgencmd ; then
            # it's probably a Raspbian install, so show a message about expanding the filesystem
            printf "      If this is a new install you may need to expand your disk\\n"
            printf "      Run 'sudo raspi-config', and choose the 'expand file system' option\\n"
            printf "      After rebooting, run this installation again\\n"
        fi
        # Show there is not enough free space
        printf "\\n      %bInsufficient free space, exiting...%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
        # and exit with an error
        exit 1
    # Otherwise,
    else
        # Show that we're running a disk space check
        printf "  %b %s\\n" "${TICK}" "${str}"
    fi
}

# A function to setup the wan interface
setupWlanInterface() {
    WLAN_AP=0
    local countIface=0
    # Turn the available interfaces into an array so it can be used with a whiptail dialog
    local interfacesArray=()
    # Number of available interfaces
    local interfaceCount
    # Whiptail variable storage
    local chooseInterfaceCmd
    # Temporary Whiptail options storage
    local chooseInterfaceOptions
    # Loop sentinel variable
    local firstLoop=1
    local str="Checking for available wireless interface"
    printf "%b  %b %s...\\n" "${OVER}" "${INFO}" "${str}"
    # Find out how many interfaces are available to choose from
    interfaceCount=$(wc -l <<< "${availableWlanInterfaces}")

    # If there is one interface,
    if [[ "${interfaceCount}" -ge 1 ]]; then
        # While reading through the available interfaces
        if whiptail --backtitle "Setting up wireless interface" --title "Wireless Access Point Configuration" --yesno "Do you want to enable wireless access point?" "${r}" "${c}"; then
            while read -r line; do
                # use a variable to set the option as OFF to begin with
                mode="OFF"
                # If it's the first loop,
                if [[ "${firstLoop}" -eq 1 ]]; then
                    # set this as the interface to use (ON)
                    firstLoop=0
                    mode="ON"
                fi
                # Put all these interfaces into an array
                interfacesArray+=("${line}" "available" "${mode}")
            # Feed the available interfaces into this while loop
            done <<< "${availableWlanInterfaces}"
            # The whiptail command that will be run, stored in a variable
            chooseInterfaceCmd=(whiptail --separate-output --radiolist "Choose the WLAN Interface (press space to toggle selection)" "${r}" "${c}" "${interfaceCount}")
            # Now run the command using the interfaces saved into the array
            chooseInterfaceOptions=$("${chooseInterfaceCmd[@]}" "${interfacesArray[@]}" 2>&1 >/dev/tty) || \
            # If the user chooses Cancel, exit
            { printf "  %bCancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
            # For each interface
            for desiredInterface in ${chooseInterfaceOptions}; do
                # Set the one the user selected as the interface to use
                PIKONEK_WLAN_INTERFACE=${desiredInterface}
                # and show this information to the user
                printf "  %b Using WLAN interface: %s\\n" "${INFO}" "${PIKONEK_WLAN_INTERFACE}"
            done
            WLAN_AP=1
            # set up ip
            getStaticIPv4WlanSettings
            # Set up ap
            do_wifi_ap           
        else
            printf "%b  %b %s...\\n" "${OVER}" "${INFO}" "${str}"
        fi

    else
        str="No available wireless interface"
        printf "%b  %b %s...\\" "${OVER}" "${INFO}" "${str}"
    fi
}

configureWirelessAP() {
    local str="Configuring wireless access point configuration"
    printf "  %b %s...\\n" "${INFO}" "${str}"
    if pikonek -w /etc/pikonek/configs/pikonek_wpa_mapping.yaml &> /dev/null; then
        printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
    else
        printf "\\t\\t%bError: Unable to configure wireless access point, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
        return 1
    fi
}

get_wifi_country() {
    CODE=${1:-0}
    if ! wpa_cli -i "$PIKONEK_WLAN_INTERFACE" status > /dev/null 2>&1; then
        whiptail --msgbox "Could not communicate with wpa_supplicant" 20 60
        return 1
    fi
    wpa_cli -i "$PIKONEK_WLAN_INTERFACE" save_config > /dev/null 2>&1
    COUNTRY="$(wpa_cli -i "$PIKONEK_WLAN_INTERFACE" get country)"
    if [ "$COUNTRY" = "FAIL" ]; then
        return 1
    fi

    if [ $CODE = 0 ]; then
        echo "$COUNTRY"
    fi

    return 0
}

list_wlan_interfaces() {
  for dir in /sys/class/net/*/wireless; do
    if [ -d "$dir" ]; then
      basename "$(dirname "$dir")"
    fi
  done
}

do_wifi_ap() {
    ap_mode=2
    psk=""
    IFACE_LIST="$(list_wlan_interfaces)"
    if ! wpa_cli -i "$PIKONEK_WLAN_INTERFACE" status > /dev/null 2>&1; then
        whiptail --msgbox "Could not communicate with wpa_supplicant" 20 60
        return 1
    fi

    # Install wpa_supplicant.conf       
    install -m 0644 ${PIKONEK_LOCAL_REPO}/configs/wpa_supplicant.conf /etc/wpa_supplicant/wpa_supplicant.conf

    if [ -z "$(get_wifi_country)" ]; then
        do_wifi_country
    fi

    SSID="$1"
    while [ -z "$SSID" ]; do
        SSID=$(whiptail --inputbox "Please enter SSID" "${r}" "${c}" 3>&1 1>&2 2>&3)
        if [ $? -ne 0 ]; then
            return 0
        elif [ -z "$SSID" ]; then
            whiptail --msgbox "SSID cannot be empty. Please try again." "${r}" "${c}"
        fi
    done

    if whiptail --yesno "Do you want to enable passphrase?" "${r}" "${c}"; then
        PASSPHRASE=""
        local pass_length=$(expr length "$PASSPHRASE")
        while [ "$pass_length" -lt 8 ]; do
            PASSPHRASE=$(whiptail --passwordbox "Please enter passphrase. Must be min of 8 characters in length." "${r}" "${c}" 3>&1 1>&2 2>&3)
            pass_length=$(expr length "$PASSPHRASE")
            if [ $? -ne 0 ]; then
                return 0
            elif [ -z "$PASSPHRASE" ]; then
                whiptail --msgbox "PASSPHRASE cannot be empty. Please try again." "${r}" "${c}"
            fi
        done
    fi

    # Escape special characters for embedding in regex below
    local ssid="$(echo "$SSID" \
    | sed 's;\\;\\\\;g' \
    | sed -e 's;\.;\\\.;g' \
            -e 's;\*;\\\*;g' \
            -e 's;\+;\\\+;g' \
            -e 's;\?;\\\?;g' \
            -e 's;\^;\\\^;g' \
            -e 's;\$;\\\$;g' \
            -e 's;\/;\\\/;g' \
            -e 's;\[;\\\[;g' \
            -e 's;\];\\\];g' \
            -e 's;{;\\{;g'   \
            -e 's;};\\};g'   \
            -e 's;(;\\(;g'   \
            -e 's;);\\);g'   \
            -e 's;";\\\\\";g')"
    
    # ID="$(wpa_cli -i "$PIKONEK_WLAN_INTERFACE" add_network)"
    # wpa_cli -i "$PIKONEK_WLAN_INTERFACE" set_network "$ID" ssid "\"$SSID\"" 2>&1 | grep -q "OK"
    # RET=$((RET + $?))
    # # set the mode to 2 -- for ap
    # wpa_cli -i "$PIKONEK_WLAN_INTERFACE" set_network "$ID" mode 2 2>&1 | grep -q "OK"
    # RET=$((RET + $?))

    if [ -z "$PASSPHRASE" ]; then
        # wpa_cli -i "$PIKONEK_WLAN_INTERFACE" set_network "$ID" key_mgmt NONE 2>&1 | grep -q "OK"
        # RET=$((RET + $?))
        key_mgmt="NONE"
    else
        # wpa_cli -i "$PIKONEK_WLAN_INTERFACE" set_network "$ID" key_mgmt WPA-PSK 2>&1 | grep -q "OK"
        # wpa_cli -i "$PIKONEK_WLAN_INTERFACE" set_network "$ID" psk "\"$PASSPHRASE\"" 2>&1 | grep -q "OK"
        # RET=$((RET + $?))
        psk="$PASSPHRASE"
        key_mgmt="WPA-PSK"
    fi

    # if [ $RET -eq 0 ]; then
    #     wpa_cli -i "$PIKONEK_WLAN_INTERFACE" enable_network "$ID" > /dev/null 2>&1
    # else
    #     wpa_cli -i "$PIKONEK_WLAN_INTERFACE" remove_network "$ID" > /dev/null 2>&1
    #     whiptail --msgbox "Failed to set SSID or passphrase" 20 60
    # fi
    # wpa_cli -i "$PIKONEK_WLAN_INTERFACE" save_config > /dev/null 2>&1

    # echo "$IFACE_LIST" | while read IFACE; do
    #     wpa_cli -i "$IFACE" reconfigure > /dev/null 2>&1
    # done

    # return $RET
}


do_wifi_country() {
    if ! wpa_cli -i "$PIKONEK_WLAN_INTERFACE" status > /dev/null 2>&1; then
        whiptail --msgbox "Could not communicate with wpa_supplicant" 20 60
        return 1
    fi

    oIFS="$IFS"
    IFS="/"
    value=$(cat /usr/share/zoneinfo/iso3166.tab | tail -n +26 | tr '\t' '/' | tr '\n' '/')
    COUNTRY=$(whiptail --menu "Select the country in which the PiKonek is to be used" 20 60 10 ${value} 3>&1 1>&2 2>&3)

    if [ $? -eq 0 ];then
        wpa_cli -i "$PIKONEK_WLAN_INTERFACE" set country "$COUNTRY" > /dev/null 2>&1
        wpa_cli -i "$PIKONEK_WLAN_INTERFACE" save_config > /dev/null 2>&1
    fi

    whiptail --msgbox "Wireless LAN country set to $COUNTRY" 20 60 1
    str="Wireless LAN country set to $COUNTRY"
    printf "%b  %b %s...\\n" "${OVER}" "${INFO}" "${str}"
}

# A function to setup the wan interface
setupWanInterface() {
    local countIface=0
    # Turn the available interfaces into an array so it can be used with a whiptail dialog
    local interfacesArray=()
    # Number of available interfaces
    local interfaceCount
    # Whiptail variable storage
    local chooseInterfaceCmd
    # Temporary Whiptail options storage
    local chooseInterfaceOptions
    # Loop sentinel variable
    local firstLoop=1

    # Find out how many interfaces are available to choose from
    interfaceCount=$(wc -l <<< "${availableInterfaces}")

    # If there is one interface,
    if [[ "${interfaceCount}" -eq 1 ]]; then
        countIface=1
        # Set it as the interface to use since there is no other option
        # PIKONEK_WAN_INTERFACE="${availableInterfaces}"
        # printf "  %b Using WAN interface: %s\\n" "${INFO}" "${PIKONEK_WAN_INTERFACE}"
    fi
    # Otherwise,
    # While reading through the available interfaces
    while read -r line; do
        # use a variable to set the option as OFF to begin with
        mode="OFF"
        # If it's the first loop,
        if [[ "${firstLoop}" -eq 1 ]]; then
            # set this as the interface to use (ON)
            firstLoop=0
            mode="ON"
        fi
        # Put all these interfaces into an array
        interfacesArray+=("${line}" "available" "${mode}")
    # Feed the available interfaces into this while loop
    done <<< "${availableInterfaces}"
    # The whiptail command that will be run, stored in a variable
    chooseInterfaceCmd=(whiptail --separate-output --radiolist "Choose the WAN Interface (press space to toggle selection)" "${r}" "${c}" "${interfaceCount}")
    # Now run the command using the interfaces saved into the array
    chooseInterfaceOptions=$("${chooseInterfaceCmd[@]}" "${interfacesArray[@]}" 2>&1 >/dev/tty) || \
    # If the user chooses Cancel, exit
    { printf "  %bCancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
    # For each interface
    for desiredInterface in ${chooseInterfaceOptions}; do
        # Set the one the user selected as the interface to use
        PIKONEK_WAN_INTERFACE=${desiredInterface}
        # and show this information to the user
        printf "  %b Using WAN interface: %s\\n" "${INFO}" "${PIKONEK_WAN_INTERFACE}"
    done

    find_IPv4_information
    getStaticIPv4WanSettings
}

count=0
# A function to setup the lan interface
setupLanInterface() {
    local countIface=0
    # Turn the available interfaces into an array so it can be used with a whiptail dialog
    local interfacesArray=()
    # Number of available interfaces
    local interfaceCount
    # Whiptail variable storage
    local chooseInterfaceCmd
    # Temporary Whiptail options storage
    local chooseInterfaceOptions
    # Loop sentinel variable
    local firstLoop=1

    # Find out how many interfaces are available to choose from
    interfaceCount=$(wc -l <<< "${availableInterfaces}")

    # If there is one interface,
    if [[ "${interfaceCount}" -eq 1 ]]; then
        # Set it as the interface to use since there is no other option
        countIface=1
        interfaceCount=2
        # printf "  %b Using LAN interface: %s\\n" "${INFO}" "${PIKONEK_LAN_INTERFACE}"
    fi
    # Otherwise,
    # While reading through the available interfaces
    mode="OFF"
    while read -r line; do
        # use a variable to set the option as OFF to begin with
        # Put all these interfaces into an array

        if [ "$countIface" -eq 1 ]; then
            # Put all these interfaces into an array
            interfacesArray+=("eth1" "available" "ON")
        else
            if [ "$line" != "$PIKONEK_WAN_INTERFACE" ]; then
                if [ $mode == "OFF" ]; then
                    mode="ON"
                    count=$((count+1))
                fi
                # If it equals 1,
                # if [[ "${count}" == 1 ]]; then
                #     #
                #     mode="OFF"
                # fi

                interfacesArray+=("${line}" "available" "${mode}")
            fi
        fi

    # Feed the available interfaces into this while loop
    done <<< "${availableInterfaces}"
    # The whiptail command that will be run, stored in a variable
    chooseInterfaceCmd=(whiptail --separate-output --radiolist "Choose the LAN Interface (press space to toggle selection)" "${r}" "${c}" "${interfaceCount}")
    # Now run the command using the interfaces saved into the array
    chooseInterfaceOptions=$("${chooseInterfaceCmd[@]}" "${interfacesArray[@]}" 2>&1 >/dev/tty) || \
    # If the user chooses Cancel, exit
    { printf "  %bCancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
    # For each interface
    for desiredInterface in ${chooseInterfaceOptions}; do
        # Set the one the user selected as the interface to use
        PIKONEK_LAN_INTERFACE=${desiredInterface}
        # and show this information to the user
        printf "  %b Using LAN interface: %s\\n" "${INFO}" "${PIKONEK_LAN_INTERFACE}"
    done

    getStaticIPv4LanSettings
}

getStaticIPv4WanSettings() {
    # Local, named variables
    local ipSettingsCorrect
    # Ask if the user wants to use DHCP settings as their static IP
    # This is useful for users that are using DHCP reservations; then we can just use the information gathered via our functions
    if whiptail --backtitle "Calibrating network interface" --title "WAN IP Address Assignment" --yesno "Do you want to use DHCP to assign ip address for WAN Interface?" "${r}" "${c}"; then
        PIKONEK_WAN_DHCP_INTERFACE=true
    else
    # Otherwise, we need to ask the user to input thesir deired settings.
    # Start by getting the IPv4 address (pre-filling it with info gathered from DHCP)
    # Start a loop to let the user enter their information with the chance to go back and edit it if necessary
        until [[ "${ipSettingsCorrect}" = True ]]; do
            # Ask for the IPv4 address
            WAN_IPV4_ADDRESS=$(whiptail --backtitle "Calibrating network interface" --title "IPv4 address" --inputbox "Enter your desired IPv4 address" "${r}" "${c}" "${IPV4_ADDRESS}" 3>&1 1>&2 2>&3) || \
            # Canceling IPv4 settings window
            { ipSettingsCorrect=False; echo -e "  ${COL_LIGHT_RED}Cancel was selected, exiting installer${COL_NC}"; exit 1; }
            printf "  %b Your static IPv4 address: %s\\n" "${INFO}" "${IPV4_ADDRESS}"

            # Ask for the gateway
            WAN_IPv4gw=$(whiptail --backtitle "Calibrating network interface" --title "IPv4 gateway (router)" --inputbox "Enter your desired IPv4 default gateway" "${r}" "${c}" "${IPv4gw}" 3>&1 1>&2 2>&3) || \
            # Canceling gateway settings window
            { ipSettingsCorrect=False; echo -e "  ${COL_LIGHT_RED}Cancel was selected, exiting installer${COL_NC}"; exit 1; }
            printf "  %b Your static IPv4 gateway: %s\\n" "${INFO}" "${IPv4gw}"
            PIKONEK_WAN_DHCP_INTERFACE=false
            # Give the user a chance to review their settings before moving on
            if whiptail --backtitle "Calibrating network interface" --title "Static IP Address" --yesno "Are these settings correct?
                IP address: ${WAN_IPV4_ADDRESS}
                Gateway:    ${WAN_IPv4gw}" "${r}" "${c}"; then
                    # After that's done, the loop ends and we move on
                    ipSettingsCorrect=True
            else
                # If the settings are wrong, the loop continues
                ipSettingsCorrect=False
            fi
        done
    fi
}

getStaticIPv4WlanSettings() {
    # Local, named variables
    local ipSettingsCorrect
    local ipRangeSettingsCorrect
    PIKONEK_WLAN_DHCP_INTERFACE=false
    WLAN_IPV4_ADDRESS="192.168.0.1/24"
    # Ask if the user wants to use DHCP settings as their static IP
    # This is useful for users that are using DHCP reservations; then we can just use the information gathered via our functions
    whiptail --title "WLAN Static IP Address" --msgbox "Configure IPv4 Static Address for WLAN Interface." "${r}" "${c}"
    # Otherwise, we need to ask the user to input their desired settings.
    # Start by getting the IPv4 address (pre-filling it with info gathered from DHCP)
    # Start a loop to let the user enter their information with the chance to go back and edit it if necessary
    until [[ "${ipSettingsCorrect}" = True ]]; do
        # Ask for the IPv4 address
        WLAN_IPV4_ADDRESS=$(whiptail --backtitle "Calibrating network interface" --title "IPv4 address" --inputbox "Enter your desired IPv4 address ie. 192.168.0.1/24" "${r}" "${c}" "${WLAN_IPV4_ADDRESS}" 3>&1 1>&2 2>&3) || \
        # Canceling IPv4 settings window
        { ipSettingsCorrect=False; echo -e "  ${COL_LIGHT_RED}Cancel was selected, exiting installer${COL_NC}"; exit 1; }
        printf "  %b Your WLAN static IPv4 address: %s\\n" "${INFO}" "${WLAN_IPV4_ADDRESS}"
        PIKONEK_WLAN_DHCP_INTERFACE=false
        # Give the user a chance to review their settings before moving on
        if whiptail --backtitle "Calibrating network interface" --title "Static IP Address" --yesno "Are these settings correct?
            IP address: ${WLAN_IPV4_ADDRESS}" "${r}" "${c}"; then
                # After that's done, the loop ends and we move on
                ipSettingsCorrect=True
        else
            # If the settings are wrong, the loop continues
            ipSettingsCorrect=False
        fi
    done
    # Set dhcp range
    until [[ "${ipRangeSettingsCorrect}" = True ]]; do
        #
        strInvalid="Invalid"
        # If the first
        if [[ ! "${wpikonek_RANGE_1}" ]]; then
            # and second upstream servers do not exist
            if [[ ! "${wpikonek_RANGE_2}" ]]; then
                prePopulate=""
            # Otherwise,
            else
                prePopulate=", ${wpikonek_RANGE_2}"
            fi
        elif  [[ "${wpikonek_RANGE_1}" ]] && [[ ! "${wpikonek_RANGE_2}" ]]; then
            prePopulate="${wpikonek_RANGE_1}"
        elif [[ "${wpikonek_RANGE_1}" ]] && [[ "${wpikonek_RANGE_2}" ]]; then
            prePopulate="${wpikonek_RANGE_1}, ${wpikonek_RANGE_2}"
        fi

        # Dialog for the user to enter custom upstream servers
        wpikonekRange=$(whiptail --backtitle "Specify the dhcp range"  --inputbox "Enter your desired dhcp range, separated by a comma.\\n\\nFor example '192.168.0.100, 192.168.0.200'" "${r}" "${c}" "${prePopulate}" 3>&1 1>&2 2>&3) || \
        { printf "  %bCancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
        # Clean user input and replace whitespace with comma.
        wpikonekRange=$(sed 's/[, \t]\+/,/g' <<< "${wpikonekRange}")

        printf -v wpikonek_RANGE_1 "%s" "${wpikonekRange%%,*}"
        printf -v wpikonek_RANGE_2 "%s" "${wpikonekRange##*,}"

        # If the IP is valid,
        if ! valid_ip "${wpikonek_RANGE_1}" || [[ ! "${wpikonek_RANGE_1}" ]]; then
            # store it in the variable so we can use it
            wpikonek_RANGE_1=${strInvalid}
        fi
        # Do the same for the secondary server
        if ! valid_ip "${wpikonek_RANGE_2}" && [[ "${wpikonek_RANGE_2}" ]]; then
            wpikonek_RANGE_2=${strInvalid}
        fi
        # If either of the IP Address are invalid,
        if [[ "${wpikonek_RANGE_1}" == "${strInvalid}" ]] || [[ "${wpikonek_RANGE_2}" == "${strInvalid}" ]]; then
            # explain this to the user
            whiptail --msgbox --backtitle "Invalid IP" --title "Invalid IP" "One or both entered IP addresses were invalid. Please try again.\\n\\n    IP Address 1:   $wpikonek_RANGE_2\\n    IP Address 2:   ${wpikonek_RANGE_2}" ${r} ${c}
            # and set the variables back to nothing
            if [[ "${wpikonek_RANGE_1}" == "${strInvalid}" ]]; then
                wpikonek_RANGE_1=""
            fi
            if [[ "${wpikonek_RANGE_2}" == "${strInvalid}" ]]; then
                wpikonek_RANGE_2=""
            fi
            # Since the settings will not work, stay in the loop
            ipRangeSettingsCorrect=False
        # Otherwise,
        else
            # Show the settings
            if (whiptail --backtitle "Specify DHCP Range(s)" --title "DHCP Range(s)" --yesno "Are these settings correct?\\n    IP Address 1:   $wpikonek_RANGE_1\\n    IP Address 2:   ${wpikonek_RANGE_2}" "${r}" "${c}"); then
                # and break from the loop since the servers are valid
                ipRangeSettingsCorrect=True
            # Otherwise,
            else
                # If the settings are wrong, the loop continues
                ipRangeSettingsCorrect=False
            fi
        fi
    done
}

getStaticIPv4LanSettings() {
    # Local, named variables
    local ipSettingsCorrect
    local ipRangeSettingsCorrect
    PIKONEK_LAN_DHCP_INTERFACE=false
    LAN_IPV4_ADDRESS="10.0.0.1/24"
    # Ask if the user wants to use DHCP settings as their static IP
    # This is useful for users that are using DHCP reservations; then we can just use the information gathered via our functions
    whiptail --title "LAN Static IP Address" --msgbox "Configure IPv4 Static Address for LAN Interface." "${r}" "${c}"
    # Otherwise, we need to ask the user to input their desired settings.
    # Start by getting the IPv4 address (pre-filling it with info gathered from DHCP)
    # Start a loop to let the user enter their information with the chance to go back and edit it if necessary
    until [[ "${ipSettingsCorrect}" = True ]]; do
        # Ask for the IPv4 address
        LAN_IPV4_ADDRESS=$(whiptail --backtitle "Calibrating network interface" --title "IPv4 address" --inputbox "Enter your desired IPv4 address ie. 10.0.0.1/24" "${r}" "${c}" "${LAN_IPV4_ADDRESS}" 3>&1 1>&2 2>&3) || \
        # Canceling IPv4 settings window
        { ipSettingsCorrect=False; echo -e "  ${COL_LIGHT_RED}Cancel was selected, exiting installer${COL_NC}"; exit 1; }
        printf "  %b Your LAN static IPv4 address: %s\\n" "${INFO}" "${LAN_IPV4_ADDRESS}"
        PIKONEK_LAN_DHCP_INTERFACE=false
        # Give the user a chance to review their settings before moving on
        if whiptail --backtitle "Calibrating network interface" --title "Static IP Address" --yesno "Are these settings correct?
            IP address: ${LAN_IPV4_ADDRESS}" "${r}" "${c}"; then
                # After that's done, the loop ends and we move on
                ipSettingsCorrect=True
        else
            # If the settings are wrong, the loop continues
            ipSettingsCorrect=False
        fi
    done
    # Set dhcp range
    until [[ "${ipRangeSettingsCorrect}" = True ]]; do
        #
        strInvalid="Invalid"
        # If the first
        if [[ ! "${pikonek_RANGE_1}" ]]; then
            # and second upstream servers do not exist
            if [[ ! "${pikonek_RANGE_2}" ]]; then
                prePopulate=""
            # Otherwise,
            else
                prePopulate=", ${pikonek_RANGE_2}"
            fi
        elif  [[ "${pikonek_RANGE_1}" ]] && [[ ! "${pikonek_RANGE_2}" ]]; then
            prePopulate="${pikonek_RANGE_1}"
        elif [[ "${pikonek_RANGE_1}" ]] && [[ "${pikonek_RANGE_2}" ]]; then
            prePopulate="${pikonek_RANGE_1}, ${pikonek_RANGE_2}"
        fi

        # Dialog for the user to enter custom upstream servers
        pikonekRange=$(whiptail --backtitle "Specify the dhcp range"  --inputbox "Enter your desired dhcp range, separated by a comma.\\n\\nFor example '10.0.0.100, 10.0.0.200'" "${r}" "${c}" "${prePopulate}" 3>&1 1>&2 2>&3) || \
        { printf "  %bCancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
        # Clean user input and replace whitespace with comma.
        pikonekRange=$(sed 's/[, \t]\+/,/g' <<< "${pikonekRange}")

        printf -v pikonek_RANGE_1 "%s" "${pikonekRange%%,*}"
        printf -v pikonek_RANGE_2 "%s" "${pikonekRange##*,}"

        # If the IP is valid,
        if ! valid_ip "${pikonek_RANGE_1}" || [[ ! "${pikonek_RANGE_1}" ]]; then
            # store it in the variable so we can use it
            pikonek_RANGE_1=${strInvalid}
        fi
        # Do the same for the secondary server
        if ! valid_ip "${pikonek_RANGE_2}" && [[ "${pikonek_RANGE_2}" ]]; then
            pikonek_RANGE_2=${strInvalid}
        fi
        # If either of the IP Address are invalid,
        if [[ "${pikonek_RANGE_1}" == "${strInvalid}" ]] || [[ "${pikonek_RANGE_2}" == "${strInvalid}" ]]; then
            # explain this to the user
            whiptail --msgbox --backtitle "Invalid IP" --title "Invalid IP" "One or both entered IP addresses were invalid. Please try again.\\n\\n    IP Address 1:   $pikonek_RANGE_2\\n    IP Address 2:   ${pikonek_RANGE_2}" ${r} ${c}
            # and set the variables back to nothing
            if [[ "${pikonek_RANGE_1}" == "${strInvalid}" ]]; then
                pikonek_RANGE_1=""
            fi
            if [[ "${pikonek_RANGE_2}" == "${strInvalid}" ]]; then
                pikonek_RANGE_2=""
            fi
            # Since the settings will not work, stay in the loop
            ipRangeSettingsCorrect=False
        # Otherwise,
        else
            # Show the settings
            if (whiptail --backtitle "Specify DHCP Range(s)" --title "DHCP Range(s)" --yesno "Are these settings correct?\\n    IP Address 1:   $pikonek_RANGE_1\\n    IP Address 2:   ${pikonek_RANGE_2}" "${r}" "${c}"); then
                # and break from the loop since the servers are valid
                ipRangeSettingsCorrect=True
            # Otherwise,
            else
                # If the settings are wrong, the loop continues
                ipRangeSettingsCorrect=False
            fi
        fi
    done
}

getStaticIPv4Settings() {
    # Local, named variables
    local ipSettingsCorrect
    # Ask if the user wants to use DHCP settings as their static IP
    # This is useful for users that are using DHCP reservations; then we can just use the information gathered via our functions
    if whiptail --backtitle "Calibrating network interface" --title "Static IP Address" --yesno "Do you want to use your current network settings as a static address?
          IP address:    ${IPV4_ADDRESS}
          Gateway:       ${IPv4gw}" "${r}" "${c}"; then
        # If they choose yes, let the user know that the IP address will not be available via DHCP and may cause a conflict.
        whiptail --msgbox --backtitle "IP information" --title "FYI: IP Conflict" "It is possible your router could still try to assign this IP to a device, which would cause a conflict.  But in most cases the router is smart enough to not do that.
If you are worried, either manually set the address, or modify the DHCP reservation pool so it does not include the IP you want.
It is also possible to use a DHCP reservation, but if you are going to do that, you might as well set a static address." "${r}" "${c}"
    # Nothing else to do since the variables are already set above
    else
    # Otherwise, we need to ask the user to input their desired settings.
    # Start by getting the IPv4 address (pre-filling it with info gathered from DHCP)
    # Start a loop to let the user enter their information with the chance to go back and edit it if necessary
    until [[ "${ipSettingsCorrect}" = True ]]; do

        # Ask for the IPv4 address
        IPV4_ADDRESS=$(whiptail --backtitle "Calibrating network interface" --title "IPv4 address" --inputbox "Enter your desired IPv4 address" "${r}" "${c}" "${IPV4_ADDRESS}" 3>&1 1>&2 2>&3) || \
        # Canceling IPv4 settings window
        { ipSettingsCorrect=False; echo -e "  ${COL_LIGHT_RED}Cancel was selected, exiting installer${COL_NC}"; exit 1; }
        printf "  %b Your static IPv4 address: %s\\n" "${INFO}" "${IPV4_ADDRESS}"

        # Ask for the gateway
        IPv4gw=$(whiptail --backtitle "Calibrating network interface" --title "IPv4 gateway (router)" --inputbox "Enter your desired IPv4 default gateway" "${r}" "${c}" "${IPv4gw}" 3>&1 1>&2 2>&3) || \
        # Canceling gateway settings window
        { ipSettingsCorrect=False; echo -e "  ${COL_LIGHT_RED}Cancel was selected, exiting installer${COL_NC}"; exit 1; }
        printf "  %b Your static IPv4 gateway: %s\\n" "${INFO}" "${IPv4gw}"

        # Give the user a chance to review their settings before moving on
        if whiptail --backtitle "Calibrating network interface" --title "Static IP Address" --yesno "Are these settings correct?
            IP address: ${IPV4_ADDRESS}
            Gateway:    ${IPv4gw}" "${r}" "${c}"; then
                # After that's done, the loop ends and we move on
                ipSettingsCorrect=True
        else
            # If the settings are wrong, the loop continues
            ipSettingsCorrect=False
        fi
    done
    # End the if statement for DHCP vs. static
    fi
}

# Check an IP address to see if it is a valid one
valid_ip() {
    # Local, named variables
    local ip=${1}
    local stat=1

    # One IPv4 element is 8bit: 0 - 256
    local ipv4elem="(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)";
    # optional port number starting '#' with range of 1-65536
    local portelem="(#([1-9]|[1-8][0-9]|9[0-9]|[1-8][0-9]{2}|9[0-8][0-9]|99[0-9]|[1-8][0-9]{3}|9[0-8][0-9]{2}|99[0-8][0-9]|999[0-9]|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-6]))?"
    # build a full regex string from the above parts
    local regex="^${ipv4elem}\.${ipv4elem}\.${ipv4elem}\.${ipv4elem}${portelem}$"

    [[ $ip =~ ${regex} ]]

    stat=$?
    # Return the exit code
    return "${stat}"
}

valid_ip6() {
    local ip=${1}
    local stat=1

    # One IPv6 element is 16bit: 0000 - FFFF
    local ipv6elem="[0-9a-fA-F]{1,4}"
    # CIDR for IPv6 is 1- 128 bit
    local v6cidr="(\\/([1-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8])){0,1}"
    # build a full regex string from the above parts
    local regex="^(((${ipv6elem}))((:${ipv6elem}))*::((${ipv6elem}))*((:${ipv6elem}))*|((${ipv6elem}))((:${ipv6elem})){7})${v6cidr}$"

    [[ ${ip} =~ ${regex} ]]

    stat=$?
    # Return the exit code
    return "${stat}"
}

# A function to choose the upstream DNS provider(s)
setDNS() {
    # Local, named variables
    local DNSSettingsCorrect

    # In an array, list the available upstream providers
    DNSChooseOptions=()
    local DNSServerCount=0
    # Save the old Internal Field Separator in a variable
    OIFS=$IFS
    # and set the new one to newline
    IFS=$'\n'
    # Put the DNS Servers into an array
    for DNSServer in ${DNS_SERVERS}
    do
        DNSName="$(cut -d';' -f1 <<< "${DNSServer}")"
        DNSChooseOptions[DNSServerCount]="${DNSName}"
        (( DNSServerCount=DNSServerCount+1 ))
        DNSChooseOptions[DNSServerCount]=""
        (( DNSServerCount=DNSServerCount+1 ))
    done
    DNSChooseOptions[DNSServerCount]="Custom"
    (( DNSServerCount=DNSServerCount+1 ))
    DNSChooseOptions[DNSServerCount]=""
    # Restore the IFS to what it was
    IFS=${OIFS}
    # In a whiptail dialog, show the options
    DNSchoices=$(whiptail --separate-output --menu "Select Upstream DNS Provider. To use your own, select Custom." "${r}" "${c}" 7 \
    "${DNSChooseOptions[@]}" 2>&1 >/dev/tty) || \
    # exit if Cancel is selected
    { printf "  %bCancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }

    # Depending on the user's choice, set the GLOBAl variables to the IP of the respective provider
    if [[ "${DNSchoices}" == "Custom" ]]
    then
        # Until the DNS settings are selected,
        until [[ "${DNSSettingsCorrect}" = True ]]; do
            #
            strInvalid="Invalid"
            # If the first
            if [[ ! "${pikonek_DNS_1}" ]]; then
                # and second upstream servers do not exist
                if [[ ! "${pikonek_DNS_2}" ]]; then
                    prePopulate=""
                # Otherwise,
                else
                    prePopulate=", ${pikonek_DNS_2}"
                fi
            elif  [[ "${pikonek_DNS_1}" ]] && [[ ! "${pikonek_DNS_2}" ]]; then
                prePopulate="${pikonek_DNS_1}"
            elif [[ "${pikonek_DNS_1}" ]] && [[ "${pikonek_DNS_2}" ]]; then
                prePopulate="${pikonek_DNS_1}, ${pikonek_DNS_2}"
            fi

            # Dialog for the user to enter custom upstream servers
            pikonekDNS=$(whiptail --backtitle "Specify Upstream DNS Provider(s)"  --inputbox "Enter your desired upstream DNS provider(s), separated by a comma.\\n\\nFor example '8.8.8.8, 8.8.4.4'" "${r}" "${c}" "${prePopulate}" 3>&1 1>&2 2>&3) || \
            { printf "  %bCancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
            # Clean user input and replace whitespace with comma.
            pikonekDNS=$(sed 's/[, \t]\+/,/g' <<< "${pikonekDNS}")

            printf -v pikonek_DNS_1 "%s" "${pikonekDNS%%,*}"
            printf -v pikonek_DNS_2 "%s" "${pikonekDNS##*,}"

            # If the IP is valid,
            if ! valid_ip "${pikonek_DNS_1}" || [[ ! "${pikonek_DNS_1}" ]]; then
                # store it in the variable so we can use it
                pikonek_DNS_1=${strInvalid}
            fi
            # Do the same for the secondary server
            if ! valid_ip "${pikonek_DNS_2}" && [[ "${pikonek_DNS_2}" ]]; then
                pikonek_DNS_2=${strInvalid}
            fi
            # If either of the DNS servers are invalid,
            if [[ "${pikonek_DNS_1}" == "${strInvalid}" ]] || [[ "${pikonek_DNS_2}" == "${strInvalid}" ]]; then
                # explain this to the user
                whiptail --msgbox --backtitle "Invalid IP" --title "Invalid IP" "One or both entered IP addresses were invalid. Please try again.\\n\\n    DNS Server 1:   $pikonek_DNS_1\\n    DNS Server 2:   ${pikonek_DNS_2}" ${r} ${c}
                # and set the variables back to nothing
                if [[ "${pikonek_DNS_1}" == "${strInvalid}" ]]; then
                    pikonek_DNS_1=""
                fi
                if [[ "${pikonek_DNS_2}" == "${strInvalid}" ]]; then
                    pikonek_DNS_2=""
                fi
                # Since the settings will not work, stay in the loop
                DNSSettingsCorrect=False
            # Otherwise,
            else
                # Show the settings
                if (whiptail --backtitle "Specify Upstream DNS Provider(s)" --title "Upstream DNS Provider(s)" --yesno "Are these settings correct?\\n    DNS Server 1:   $pikonek_DNS_1\\n    DNS Server 2:   ${pikonek_DNS_2}" "${r}" "${c}"); then
                    # and break from the loop since the servers are valid
                    DNSSettingsCorrect=True
                # Otherwise,
                else
                    # If the settings are wrong, the loop continues
                    DNSSettingsCorrect=False
                fi
            fi
        done
    else
        # Save the old Internal Field Separator in a variable
        OIFS=$IFS
        # and set the new one to newline
        IFS=$'\n'
        for DNSServer in ${DNS_SERVERS}
        do
            DNSName="$(cut -d';' -f1 <<< "${DNSServer}")"
            if [[ "${DNSchoices}" == "${DNSName}" ]]
            then
                pikonek_DNS_1="$(cut -d';' -f2 <<< "${DNSServer}")"
                pikonek_DNS_2="$(cut -d';' -f3 <<< "${DNSServer}")"
                break
            fi
        done
        # Restore the IFS to what it was
        IFS=${OIFS}
    fi

    # Display final selection
    local DNSIP=${pikonek_DNS_1}
    [[ -z ${pikonek_DNS_2} ]] || DNSIP+=", ${pikonek_DNS_2}"
    printf "  %b Using upstream DNS: %s (%s)\\n" "${INFO}" "${DNSchoices}" "${DNSIP}"
}

# Check if /etc/dnsmasq.conf is from PiKonek.  If so replace with an original and install new in .d directory
version_check_dnsmasq() {
    # Local, named variables
    local dnsmasq_conf="/etc/dnsmasq.conf"
    local dnsmasq_original_config="${PIKONEK_LOCAL_REPO}/configs/dnsmasq.conf.original"
    local dnsmasq_pikonek_01_snippet="${PIKONEK_LOCAL_REPO}/configs/01-pikonek.conf"
    local dnsmasq_pikonek_01_location="/etc/dnsmasq.d/01-pikonek.conf"

    # If the dnsmasq config file exists
    if [[ -f "${dnsmasq_conf}" ]]; then
        printf "  %b Existing dnsmasq.conf found..." "${INFO}"
        # Don't to anything
        printf " it is not a PiKonek file, leaving alone!\\n"
    else
        # If a file cannot be found,
        printf "  %b No dnsmasq.conf found... restoring default dnsmasq.conf..." "${INFO}"
        # restore the default one
        install -D -m 644 -T "${dnsmasq_original_config}" "${dnsmasq_conf}"
        printf "%b  %b No dnsmasq.conf found... restoring default dnsmasq.conf...\\n" "${OVER}"  "${TICK}"
    fi

    printf "  %b Copying 01-pikonek.conf to /etc/dnsmasq.d/01-pikonek.conf..." "${INFO}"
    # Check to see if dnsmasq directory exists (it may not due to being a fresh install and dnsmasq no longer being a dependency)
    if [[ ! -d "/etc/dnsmasq.d"  ]];then
        install -d -m 755 "/etc/dnsmasq.d"
    fi
    # Copy the new PiKonek DNS config file into the dnsmasq.d directory
    install -D -m 644 -T "${dnsmasq_pikonek_01_snippet}" "${dnsmasq_pikonek_01_location}"
    printf "%b  %b Copying 01-pikonek.conf to /etc/dnsmasq.d/01-pikonek.conf\\n" "${OVER}"  "${TICK}"
    #
    echo "conf-dir=/etc/dnsmasq.d" > "${dnsmasq_conf}"
    chmod 644 "${dnsmasq_conf}"
}

# Clean an existing installation to prepare for upgrade/reinstall
clean_existing() {
    # Local, named variables
    # ${1} Directory to clean
    local clean_directory="${1}"
    # Make ${2} the new one?
    shift
    # ${2} Array of files to remove
    local old_files=( "$@" )

    # For each script found in the old files array
    for script in "${old_files[@]}"; do
        # Remove them
        rm -f "${clean_directory}/${script}.sh"
    done
}

# Install base files and web interface
installpikonek() {
    # If the user wants to install the Web interface,
    if [[ ! -d "${webroot}" ]]; then
        # make the Web directory if necessary
        install -d -m 0755 ${webroot}
    fi

    chown ${LIGHTTPD_USER}:${LIGHTTPD_GROUP} ${webroot}
    chmod 0775 ${webroot}
    # Repair permissions if /var/www/html is not world readable
    chmod a+rx /var/www
    chmod a+rx /var/www/html
    # Give lighttpd access to the pikonek group so the web interface can acces the db
    usermod -a -G pikonek ${LIGHTTPD_USER} &> /dev/null

    # install pikonek core web service
    install -o "${USER}" -Dm755 -d "${PIKONEK_INSTALL_DIR}/pikonek"
    install -o "${USER}" -Dm755 -d "${PIKONEK_INSTALL_DIR}/packages"
    install -o "${USER}" -Dm755 -d "${PIKONEK_INSTALL_DIR}/blocked"
    cp -r ${PIKONEK_LOCAL_REPO}/pikonek/** /etc/pikonek/pikonek
    # install pikonek core init script to /etc/init.d
    install -m 0755 ${PIKONEK_INSTALL_DIR}/pikonek/etc/init.d/S70piknkmain /etc/init.d/S70piknkmain
    # install the pikonek db
    mv /etc/pikonek/pikonek/pikonek/db.wifirouter /etc/pikonek/
    # install pikonek core packages
    cp -r ${PIKONEK_LOCAL_REPO}/packages/** ${PIKONEK_INSTALL_DIR}/packages
    cp -r ${PIKONEK_LOCAL_REPO}/blocked/** ${PIKONEK_INSTALL_DIR}/blocked

    # Check if there is /etc/sysctl.conf
    if [ -e /etc/sysctl.conf ];
    then
        # Check if there is a match
        if grep -qE '#net.ipv4.ip_forward=1' /etc/sysctl.conf; then
            sed -i '/#net.ipv4.ip_forward=1/a\net.ipv4.ip_forward=1' /etc/sysctl.conf
        fi

    else
        install -m 0644 ${PIKONEK_LOCAL_REPO}/configs/sysctl.conf /etc/sysctl.conf
    fi

    # Install base files and web interface
    if ! installScripts; then
        printf "  %b Failure in dependent script copy function.\\n" "${CROSS}"
        exit 1
    fi
    # Install config files
    if ! installConfigs; then
        printf "  %b Failure in dependent config copy function.\\n" "${CROSS}"
        exit 1
    fi

    # install captive portal init script
    install -m 0755 ${PIKONEK_INSTALL_DIR}/packages/captive/init.d/S70pikonekcaptive /etc/init.d/S70pikonekcaptive
    install -m 0755 ${PIKONEK_INSTALL_DIR}/packages/captive/init.d/S70pikonekcaptivefw /etc/init.d/S70pikonekcaptivefw
    # install default blocked list
    # installDefaultBlockedList
    # install web server
    installpikonekWebServer
    # install logrotate
    installLogrotate
    # change the user to pikonek
    chown -R pikonek:pikonek /etc/pikonek
    # Install the cron file
    installCron
}

# install default blocked list
installDefaultBlockedList() {
    local str="Installing default blocker list. This may take a while"
    printf "  %b %s..." "${INFO}" "${str}"
    curl --silent -k ${PIKONEK_INSTALL_DIR}/blocked/adware https://raw.githubusercontent.com/notracking/hosts-blocklists/master/hostnames.txt > /dev/null 2>&1
    curl --silent -k https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/porn/hosts | awk '$1 == "0.0.0.0" { print "0.0.0.0 "$2}' > ${PIKONEK_INSTALL_DIR}/blocked/porn > /dev/null 2>&1
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
}

# Install the scripts from repository to their various locations
installScripts() {
    # Local, named variables
    local str="Installing scripts from ${PIKONEK_LOCAL_REPO}"
    printf "  %b %s..." "${INFO}" "${str}"

    # Install files from local core repository
    if [[ -d "${PIKONEK_LOCAL_REPO}" ]]; then
        # move into the directory
        cd "${PIKONEK_LOCAL_REPO}"
        # Install the scripts by:
        #  -o setting the owner to the user
        #  -Dm755 create all leading components of destination except the last, then copy the source to the destination and setting the permissions to 755
        #
        # This first one is the directory
        install -o "${USER}" -Dm755 -d "${PIKONEK_INSTALL_DIR}/scripts"
        # The rest are the scripts PiKonek needs
        install -o "${USER}" -Dm755 -t "${PIKONEK_INSTALL_DIR}/scripts" ./scripts/pikonekallowhitelist
        install -o "${USER}" -Dm755 -t "${PIKONEK_INSTALL_DIR}/scripts" ./scripts/pikonekupdateblockedlist
        install -o "${USER}" -Dm755 -t "${PIKONEK_INSTALL_DIR}/scripts" ./scripts/updatesoftware
        install -o "${USER}" -Dm755 -t "${PIKONEK_INSTALL_DIR}/scripts" ./scripts/pikonekcli.py
        install -o "${USER}" -Dm755 -t "${PIKONEK_INSTALL_DIR}/scripts" ./scripts/ntopng
        install -o "${USER}" -Dm755 -t "${PIKONEK_INSTALL_DIR}/scripts" ./scripts/darkstat
        install -o "${USER}" -Dm755 -t "${PIKONEK_INSTALL_DIR}/scripts" ./scripts/bandwidthd
        # Create symbolic link for pikonek cli
        ln -s ${PIKONEK_INSTALL_DIR}/scripts/pikonekcli.py /usr/local/bin/pikonek
        printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"

    # Otherwise,
    else
        # Show an error and exit
        printf "%b  %b %s\\n" "${OVER}"  "${CROSS}" "${str}"
        printf "\\t\\t%bError: Local repo %s not found, exiting installer%b\\n" "${COL_LIGHT_RED}" "${PIKONEK_LOCAL_REPO}" "${COL_NC}"
        return 1
    fi
}

# Install the configs from PIKONEK_LOCAL_REPO to their various locations
installConfigs() {
    printf "\\n  %b Installing configs from %s...\\n" "${INFO}" "${PIKONEK_LOCAL_REPO}"
    # Make sure PiKonek's config files are in place
    version_check_dnsmasq
    install -o "${USER}" -Dm755 -d "${PIKONEK_INSTALL_DIR}/configs"
    cp -r  ${PIKONEK_LOCAL_REPO}/configs/** /etc/pikonek/configs
    # and if the Web server conf directory does not exist,
    if [[ ! -d "/etc/lighttpd" ]]; then
        # make it and set the owners
        install -d -m 755 -o "${USER}" -g root /etc/lighttpd
    # Otherwise, if the config file already exists
    elif [[ -f "/etc/lighttpd/lighttpd.conf" ]]; then
        # back up the original
        mv /etc/lighttpd/lighttpd.conf /etc/lighttpd/lighttpd.conf.orig
    fi
    # and copy in the config file PiKonek needs
    install -D -m 644 -T "${PIKONEK_LOCAL_REPO}/configs/${LIGHTTPD_CFG}" /etc/lighttpd/lighttpd.conf
    # Make sure the external.conf file exists, as lighttpd v1.4.50 crashes without it
    touch /etc/lighttpd/external.conf
    chmod 644 /etc/lighttpd/external.conf
    # Make the directories if they do not exist and set the owners
    mkdir -p /run/lighttpd
    chown ${LIGHTTPD_USER}:${LIGHTTPD_GROUP} /run/lighttpd
    mkdir -p /var/cache/lighttpd/compress
    chown ${LIGHTTPD_USER}:${LIGHTTPD_GROUP} /var/cache/lighttpd/compress
    mkdir -p /var/cache/lighttpd/uploads
    chown ${LIGHTTPD_USER}:${LIGHTTPD_GROUP} /var/cache/lighttpd/uploads
}

configureDhcp() {
    local str="Configuring dhcp and dns"
    printf "  %b %s...\\n" "${INFO}" "${str}"
    if pikonek -d /etc/pikonek/configs/pikonek_dhcp_mapping.yaml &> /dev/null; then
        printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
    else
        printf "\\t\\t%bError: Unable to configure dhcp and dns, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
        return 1
    fi
}

configureNetwork() {
    local str="Configuring network interface"
    printf "  %b %s...\\n" "${INFO}" "${str}"
    if pikonek -n /etc/pikonek/configs/pikonek_net_mapping.yaml &> /dev/null; then
        printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
    else
        printf "\\t\\t%bError: Unable to configure network interface, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
        return 1
    fi
}

stop_service() {
    # Stop service passed in as argument.
    # Can softfail, as process may not be installed when this is called
    local str="Stopping ${1} service"
    printf "  %b %s..." "${INFO}" "${str}"
    if is_command systemctl ; then
        systemctl stop "${1}" &> /dev/null || true
    else
        service "${1}" stop &> /dev/null || true
    fi
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
}

# Start/Restart service passed in as argument
restart_service() {
    # Local, named variables
    local str="Restarting ${1} service"
    printf "  %b %s...\\n" "${INFO}" "${str}"
    # If systemctl exists,
    if is_command systemctl ; then
        # use that to restart the service
        systemctl restart "${1}" &> /dev/null
    # Otherwise,
    else
        # fall back to the service command
        service "${1}" restart &> /dev/null
    fi
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
}

# Enable service so that it will start with next reboot
enable_service() {
    # Local, named variables
    local str="Enabling ${1} service to start on reboot"
    printf "  %b %s..." "${INFO}" "${str}"
    # If systemctl exists,
    if is_command systemctl ; then
        # use that to enable the service
        systemctl enable "${1}" &> /dev/null
    # Otherwise,
    else
        # use update-rc.d to accomplish this
        update-rc.d "${1}" defaults &> /dev/null
    fi
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
}

# Disable service so that it will not with next reboot
disable_service() {
    # Local, named variables
    local str="Disabling ${1} service"
    printf "  %b %s..." "${INFO}" "${str}"
    # If systemctl exists,
    if is_command systemctl ; then
        # use that to disable the service
        systemctl disable "${1}" &> /dev/null
    # Otherwise,
    else
        # use update-rc.d to accomplish this
        update-rc.d "${1}" disable &> /dev/null
    fi
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
}

check_service_active() {
    # If systemctl exists,
    if is_command systemctl ; then
        # use that to check the status of the service
        systemctl is-enabled "${1}" &> /dev/null
    # Otherwise,
    else
        # fall back to service command
        service "${1}" status &> /dev/null
    fi
}

update_package_cache() {
    # Running apt-get update/upgrade with minimal output can cause some issues with
    # requiring user input (e.g password for phpmyadmin see #218)

    # Update package cache on apt based OSes. Do this every time since
    # it's quick and packages can be updated at any time.

    # Local, named variables
    local str="Update local cache of available packages"
    printf "  %b %s..." "${INFO}" "${str}"
    # Create a command from the package cache variable
    if eval "${UPDATE_PKG_CACHE}" &> /dev/null; then
        printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    # Otherwise,
    else
        # show an error and exit
        printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
        printf "  %bError: Unable to update package cache. Please try \"%s\"%b" "${COL_LIGHT_RED}" "${UPDATE_PKG_CACHE}" "${COL_NC}"
        return 1
    fi
}

# Let user know if they have outdated packages on their system and
# advise them to run a package update at soonest possible.
notify_package_updates_available() {
    # Local, named variables
    local str="Checking ${PKG_MANAGER} for upgraded packages"
    printf "\\n  %b %s..." "${INFO}" "${str}"
    # Store the list of packages in a variable
    updatesToInstall=$(eval "${PKG_COUNT}")

    if [[ -d "/lib/modules/$(uname -r)" ]]; then
        if [[ "${updatesToInstall}" -eq 0 ]]; then
            printf "%b  %b %s... up to date!\\n\\n" "${OVER}" "${TICK}" "${str}"
        else
            printf "%b  %b %s... %s updates available\\n" "${OVER}" "${TICK}" "${str}" "${updatesToInstall}"
            printf "  %b %bIt is recommended to update your OS after installing the PiKonek!%b\\n\\n" "${INFO}" "${COL_LIGHT_GREEN}" "${COL_NC}"
        fi
    else
        printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
        printf "      Kernel update detected. If the install fails, please reboot and try again\\n"
    fi
}

# Install python requirements using requirements.txt
pip_install_packages() {
    printf "  %b Installing required package for pikonek core..." "${INFO}"
    pip3 install -r "${PIKONEK_LOCAL_REPO}/pikonek/requirements.txt" || \
    { printf "  %bUnable to install required pikonek core dependencies, unable to continue%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; \
    exit 1; \
    }
}

# Uninstall python requirements using requirements.txt
pip_uninstall_packages() {
    printf "  %b Uninstalling required package for pikonek core..." "${INFO}"
    pip3 uninstall -r "${PIKONEK_LOCAL_REPO}/pikonek/requirements.txt" || \
    { printf "  %bUnable to uninstall required pikonek core dependencies, unable to continue%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; \
    exit 1; \
    }
}

# What's this doing outside of a function in the middle of nowhere?
counter=0

install_dependent_packages() {
    # Local, named variables should be used here, especially for an iterator
    # Add one to the counter
    counter=$((counter+1))
    # If it equals 1,
    if [[ "${counter}" == 1 ]]; then
        #
        printf "  %b Installer Dependency checks...\\n" "${INFO}"
    else
        #
        printf "  %b Main Dependency checks...\\n" "${INFO}"
    fi

    # Install packages passed in via argument array
    # No spinner - conflicts with set -e
    declare -a installArray

    # Debian based package install - debconf will download the entire package list
    # so we just create an array of packages not currently installed to cut down on the
    # amount of download traffic.
    # NOTE: We may be able to use this installArray in the future to create a list of package that were
    # installed by us, and remove only the installed packages, and not the entire list.
    if is_command apt-get ; then
        # For each package,
        for i in "$@"; do
            printf "  %b Checking for %s..." "${INFO}" "${i}"
            if dpkg-query -W -f='${Status}' "${i}" 2>/dev/null | grep "ok installed" &> /dev/null; then
                printf "%b  %b Checking for %s\\n" "${OVER}" "${TICK}" "${i}"
            else
                printf "%b  %b Checking for %s (will be installed)\\n" "${OVER}" "${INFO}" "${i}"
                installArray+=("${i}")
            fi
        done
        if [[ "${#installArray[@]}" -gt 0 ]]; then
            test_dpkg_lock
            printf "  %b Processing %s install(s) for: %s, please wait...\\n" "${INFO}" "${PKG_MANAGER}" "${installArray[*]}"
            printf '%*s\n' "$columns" '' | tr " " -;
            "${PKG_INSTALL[@]}" "${installArray[@]}"
            printf '%*s\n' "$columns" '' | tr " " -;
            return
        fi
        printf "\\n"
        return 0
    fi

    # Install Fedora/CentOS packages
    for i in "$@"; do
        printf "  %b Checking for %s..." "${INFO}" "${i}"
        if "${PKG_MANAGER}" -q list installed "${i}" &> /dev/null; then
            printf "%b  %b Checking for %s\\n" "${OVER}" "${TICK}" "${i}"
        else
            printf "%b  %b Checking for %s (will be installed)\\n" "${OVER}" "${INFO}" "${i}"
            installArray+=("${i}")
        fi
    done
    if [[ "${#installArray[@]}" -gt 0 ]]; then
        printf "  %b Processing %s install(s) for: %s, please wait...\\n" "${INFO}" "${PKG_MANAGER}" "${installArray[*]}"
        printf '%*s\n' "$columns" '' | tr " " -;
        "${PKG_INSTALL[@]}" "${installArray[@]}"
        printf '%*s\n' "$columns" '' | tr " " -;
        return
    fi
    printf "\\n"
    return 0
}

# Install the Web interface dashboard
installpikonekWebServer() {
    local str="Backing up index.lighttpd.html"
    printf "  %b %s..." "${INFO}" "${str}"
    # If the default index file exists,
    if [[ -f "${webroot}/index.lighttpd.html" ]]; then
        # back it up
        mv ${webroot}/index.lighttpd.html ${webroot}/index.lighttpd.orig
        printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    # Otherwise,
    else
        # don't do anything
        printf "%b  %b %s\\n" "${OVER}" "${INFO}" "${str}"
        printf "      No default index.lighttpd.html file found... not backing up\\n"
    fi

    # If the Web server has certs folder,
    if [[ ! -d "/etc/lighttpd/certs" ]]; then
        install -d -m 755 /etc/lighttpd/certs
    fi
    # Generate self signed certs
    local str="Generating self signed certificate"
    cd /etc/lighttpd/certs
    printf "\\n  %b %s..." "${INFO}" "${str}"
    openssl req -new -x509 -keyout lighttpd.pem -out lighttpd.pem -days 3650 -nodes -subj "/C=PH/ST=Camarines Sur/L=Nabua/O=PiKonek/CN=PiKonek" &> /dev/null 
    chmod 400 lighttpd.pem
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"

    # Install Sudoers file
    local str="Installing sudoer file"
    printf "\\n  %b %s..." "${INFO}" "${str}"
    # Make the .d directory if it doesn't exist
    install -d -m 755 /etc/sudoers.d/
    # and copy in the pikonek sudoers file
    install -m 0640 ${PIKONEK_LOCAL_REPO}/scripts/pikonek.sudo /etc/sudoers.d/pikonek
    # Add lighttpd user (OS dependent) to sudoers file
    echo "${LIGHTTPD_USER} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/pikonek
    echo "pikonek ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/pikonek

    # If the Web server user is lighttpd,
    if [[ "$LIGHTTPD_USER" == "lighttpd" ]]; then
        # Allow executing pikonek via sudo with Fedora
        # Usually /usr/local/bin ${PIKONEK_BIN_DIR} is not permitted as directory for sudoable programs
        echo "Defaults secure_path = /sbin:/bin:/usr/sbin:/usr/bin:${PIKONEK_BIN_DIR}" >> /etc/sudoers.d/pikonek
    fi
    # Set the strict permissions on the file
    chmod 0440 /etc/sudoers.d/pikonek
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
}

# Install the logrotate script
installLogrotate() {
    local str="Installing latest logrotate script"
    printf "\\n  %b %s..." "${INFO}" "${str}"
    # Copy the file over from the local repo
    install -D -m 644 -T ${PIKONEK_LOCAL_REPO}/scripts/logrotate /etc/logrotate.d/pikonek
    logusergroup="$(stat -c '%U %G' /var/log)"
    # If the variable has a value,
    if [[ ! -z "${logusergroup}" ]]; then
        #
        sed -i "s/# su #/su ${logusergroup}/g;" /etc/logrotate.d/pikonek
    fi
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
}

# Installs a cron file
installCron() {
    # Install the cron job
    local str="Installing latest Cron script"
    printf "\\n  %b %s..." "${INFO}" "${str}"
    # Copy the cron file over from the local repo
    # File must not be world or group writeable and must be owned by root
    install -D -m 644 -T -o root -g root ${PIKONEK_LOCAL_REPO}/scripts/pikonek.cron /etc/cron.d/pikonek
    install -D -m 755 -T -o root -g root ${PIKONEK_LOCAL_REPO}/scripts/pikonekupdateblockedlist /etc/cron.daily/pikonekupdateblockedlist
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
}

# Check if the pikonek user exists and create if it does not
create_pikonek_user() {
    local str="Checking for user 'pikonek'"
    printf "  %b %s..." "${INFO}" "${str}"
    # If the user pikonek exists,
    if id -u pikonek &> /dev/null; then
        # if group exists
        if getent group pikonek > /dev/null 2>&1; then
            # just show a success
            printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
        else
            local str="Checking for group 'pikonek'"
            printf "  %b %s..." "${INFO}" "${str}"
            local str="Creating group 'pikonek'"
            # if group can be created
            if groupadd pikonek; then
                printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
                local str="Adding user 'pikonek' to group 'pikonek'"
                printf "  %b %s..." "${INFO}" "${str}"
                # if pikonek user can be added to group pikonek
                if usermod -g pikonek pikonek; then
                    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
                else
                    printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
                fi
            else
                printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
            fi
        fi
    # Otherwise,
    else
        printf "%b  %b %s" "${OVER}" "${CROSS}" "${str}"
        local str="Creating user 'pikonek'"
        printf "%b  %b %s..." "${OVER}" "${INFO}" "${str}"
        # create her with the useradd command
        if getent group pikonek > /dev/null 2>&1; then
            # add primary group pikonek as it already exists
            if useradd -r --no-user-group -g pikonek -s /usr/sbin/nologin pikonek; then
                printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
            else
                printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
            fi
        else
            # add user pikonek with default group settings
            if useradd -r -s /usr/sbin/nologin pikonek; then
                printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
            else
                printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
            fi
        fi
    fi
}

# Get predictable name
get_net_names() {
    if grep -q "net.ifnames=0" $CMDLINE || [ "$(readlink -f /etc/systemd/network/99-default.link)" = "/dev/null" ] ; then
        echo 0
    else
        echo 1
    fi
}

do_net_names () {
    ASK_REBOOT=0
    local str="Checking for predictable names"
    printf "%b  %b %s..." "${OVER}" "${INFO}" "${str}"
    if [ $(get_net_names) -eq 1 ]; then
        str="Disabling predictable names"
        printf "%b  %b %s...\\n" "${OVER}" "${INFO}" "${str}"
        if [ is_pi -eq 1 ]; then
            if [ -f /etc/default/grub ]; then
                sed -i "s/GRUB_CMDLINE_LINUX=\"\(.*\)\"/GRUB_CMDLINE_LINUX=\"\1net.ifnames=0 biosdevname=0\"/" /etc/default/grub
            fi
        fi
        ln -sf /dev/null /etc/systemd/network/99-default.link
        printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
        echo "ASK_REBOOT=1" > /tmp/setUpVars.conf
        ASK_REBOOT=1
    fi
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
    if [ "$ASK_REBOOT" -eq 1 ]; then
        str="Your system needs to reboot to continue. Please reboot your system to continue the installation. Then run again this installer."
        printf "%b  %b %s...\\n" "${OVER}" "${INFO}" "${str}"
        exit 1
    fi

    # Add a temp file to /tmp this will automatically wipe after reboot
    if [[ -e "/tmp/setUpVars.conf" ]]; then
        str="Your system needs to reboot to continue. Please reboot your system to continue the installation. Then run again this installer."
        printf "%b  %b %s...\\n" "${OVER}" "${INFO}" "${str}"
        exit 1
    fi
 }


# Final export of variables
finalExports() {
    local lan_subnet=$(ipcalc -cn $LAN_IPV4_ADDRESS | awk 'FNR == 2 {print $2}')
    local lan_ip_v4=$(ipcalc -cn $LAN_IPV4_ADDRESS | awk 'FNR == 1 {print $2}')
    if [ "$WLAN_AP" -eq 1 ]; then
    local wlan_subnet=$(ipcalc -cn $WLAN_IPV4_ADDRESS | awk 'FNR == 2 {print $2}')
    local wlan_ip_v4=$(ipcalc -cn $WLAN_IPV4_ADDRESS | awk 'FNR == 1 {print $2}')
    fi
    # Set the pikonek_net_mapping.yaml
    {
    echo -e "network_config:"
    echo -e "- addresses:"
    echo -e "  - ip_netmask: ${LAN_IPV4_ADDRESS}"
    echo -e "  hotplug: true"
    echo -e "  is_wan: false"
    echo -e "  name: ${PIKONEK_LAN_INTERFACE}"
    echo -e "  type: interface"
    echo -e "  use_dhcp: false"
    if [ "$WLAN_AP" -eq 1 ]; then
        echo -e "- addresses:"
        echo -e "  - ip_netmask: ${WLAN_IPV4_ADDRESS}"
        echo -e "  hotplug: true"
        echo -e "  is_wan: false"
        echo -e "  access_point: true"
        echo -e "  name: ${PIKONEK_WLAN_INTERFACE}"
        echo -e "  type: interface"
        echo -e "  use_dhcp: false"
    fi
    if [ "$PIKONEK_WAN_DHCP_INTERFACE" = false ]; then
    echo -e "- addresses:"
    echo -e "  - ip_netmask: ${WAN_IPV4_ADDRESS}"
    echo -e "  hotplug: true"
    echo -e "  is_wan: true"
    echo -e "  name: ${PIKONEK_WAN_INTERFACE}"
    echo -e "  type: interface"
    echo -e "  use_dhcp: ${PIKONEK_WAN_DHCP_INTERFACE}"
    else
    echo -e "- hotplug: true"
    echo -e "  is_wan: true"
    echo -e "  name: ${PIKONEK_WAN_INTERFACE}"
    echo -e "  type: interface"
    echo -e "  use_dhcp: ${PIKONEK_WAN_DHCP_INTERFACE}"
    fi
    } > "${PIKONEK_INSTALL_DIR}/configs/pikonek_net_mapping.yaml"
    # set the pikonek_dhcp_mapping.yaml
    {
    echo -e "name_server:"
    echo -e "- ip: ${pikonek_DNS_1}"
    echo -e "- ip: ${pikonek_DNS_2}"
    echo -e "dhcp_range:"
    echo -e "- end: ${pikonek_RANGE_1}"
    echo -e "  interface: ${PIKONEK_LAN_INTERFACE}"
    echo -e "  start: ${pikonek_RANGE_2}"
    echo -e "  lease_time: infinite"
    echo -e "  subnet: ${lan_subnet}"
    if [ "$WLAN_AP" -eq 1 ]; then
    echo -e "- end: ${wpikonek_RANGE_1}"
    echo -e "  interface: ${PIKONEK_WLAN_INTERFACE}"
    echo -e "  start: ${wpikonek_RANGE_2}"
    echo -e "  lease_time: infinite"
    echo -e "  subnet: ${wlan_subnet}"
    fi
    echo -e "dhcp_option:"
    echo -e "- interface: ${PIKONEK_LAN_INTERFACE}"
    echo -e "  ipaddress: ${lan_ip_v4}"
    echo -e "  option: 3"
    if [ "$WLAN_AP" -eq 1 ]; then
    echo -e "- interface: ${PIKONEK_WLAN_INTERFACE}"
    echo -e "  ipaddress: ${wlan_ip_v4}"
    echo -e "  option: 3"
    fi
    echo -e "hosts:"
    echo -e "- ip: ${lan_ip_v4}"
    echo -e "  name: pi.konek"
    if [ "$WLAN_AP" -eq 1 ]; then
    echo -e "- ip: ${wlan_ip_v4}"
    echo -e "  name: pi.konek"
    fi 
    echo -e "interface:"
    echo -e "- name: ${PIKONEK_LAN_INTERFACE}"
    if [ "$WLAN_AP" -eq 1 ]; then
    echo -e "- name: ${PIKONEK_WLAN_INTERFACE}"
    fi
    } >> "${PIKONEK_INSTALL_DIR}/configs/pikonek_dhcp_mapping.yaml"
    # write the wpa config
    if [ "$WLAN_AP" -eq 1 ]; then
    {
    echo -e "- mode: ${ap_mode}"
    echo -e "  ssid: ${SSID}"
    echo -e "  country: ${COUNTRY}"
    if [ "$psk" != "" ]; then
    echo -e "  psk: ${psk}"
    fi
    echo -e "  key_mgmt: ${key_mgmt}"
    echo -e "  interface: ${PIKONEK_WLAN_INTERFACE}"
    } > "${PIKONEK_INSTALL_DIR}/configs/pikonek_wpa_mapping.yaml"
    fi
    # echo the information to the user
    {
    echo "WLAN_AP=${WLAN_AP}"
    echo "ASK_REBOOT=${ASK_REBOOT}"
    }>> "${setupVars}"
    chmod 644 "${setupVars}"

    # Bring in the current settings and the functions to manipulate them
    source "${setupVars}"
}

# SELinux
checkSelinux() {
    local DEFAULT_SELINUX
    local CURRENT_SELINUX
    local SELINUX_ENFORCING=0
    # Check for SELinux configuration file and getenforce command
    if [[ -f /etc/selinux/config ]] && command -v getenforce &> /dev/null; then
        # Check the default SELinux mode
        DEFAULT_SELINUX=$(awk -F= '/^SELINUX=/ {print $2}' /etc/selinux/config)
        case "${DEFAULT_SELINUX,,}" in
            enforcing)
                printf "  %b %bDefault SELinux: %s%b\\n" "${CROSS}" "${COL_RED}" "${DEFAULT_SELINUX}" "${COL_NC}"
                SELINUX_ENFORCING=1
                ;;
            *)  # 'permissive' and 'disabled'
                printf "  %b %bDefault SELinux: %s%b\\n" "${TICK}" "${COL_GREEN}" "${DEFAULT_SELINUX}" "${COL_NC}"
                ;;
        esac
        # Check the current state of SELinux
        CURRENT_SELINUX=$(getenforce)
        case "${CURRENT_SELINUX,,}" in
            enforcing)
                printf "  %b %bCurrent SELinux: %s%b\\n" "${CROSS}" "${COL_RED}" "${CURRENT_SELINUX}" "${COL_NC}"
                SELINUX_ENFORCING=1
                ;;
            *)  # 'permissive' and 'disabled'
                printf "  %b %bCurrent SELinux: %s%b\\n" "${TICK}" "${COL_GREEN}" "${CURRENT_SELINUX}" "${COL_NC}"
                ;;
        esac
    else
        echo -e "  ${INFO} ${COL_GREEN}SELinux not detected${COL_NC}";
    fi
    # Exit the installer if any SELinux checks toggled the flag
    if [[ "${SELINUX_ENFORCING}" -eq 1 ]] && [[ -z "${pikonek_SELINUX}" ]]; then
        printf "  PiKonek does not provide an SELinux policy as the required changes modify the security of your system.\\n"
        printf "  Please refer to https://wiki.centos.org/HowTos/SELinux if SELinux is required for your deployment.\\n"
        printf "\\n  %bSELinux Enforcing detected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}";
        exit 1;
    fi
}

# Installation complete message with instructions for the user
displayFinalMessage() {
    # If
    if [[ "${#1}" -gt 0 ]] ; then
        pwstring="$1"
        # else, if the dashboard password in the setup variables exists,
    elif [[ $(grep 'WEBPASSWORD' -c /etc/pikonek/setupVars.conf) -gt 0 ]]; then
        # set a variable for evaluation later
        pwstring="unchanged"
    else
        # set a variable for evaluation later
        pwstring="NOT SET"
    fi
    # Store a message in a variable and display it
    additional="View the web interface at http://pi.konek/ or http://${LAN_IPV4_ADDRESS%/*}/
Your Admin Webpage login password is ${pwstring}"

    # Final completion message to user
    whiptail --msgbox --backtitle "Make it so." --title "Installation Complete!" "Successfully installed PiKonek on your system.
Please reboot your sytem.
The install log is in /etc/pikonek.
${additional}" "${r}" "${c}"
}

fully_fetch_repo() {
    # Add upstream branches to shallow clone
    local directory="${1}"

    cd "${directory}" || return 1
    if is_repo "${directory}"; then
        git remote set-branches origin '*' || return 1
        git fetch --quiet || return 1
    else
        return 1
    fi
    return 0
}

get_available_branches() {
    # Return available branches
    local directory
    directory="${1}"
    local output

    cd "${directory}" || return 1
    # Get reachable remote branches, but store STDERR as STDOUT variable
    output=$( { git ls-remote --heads --quiet | cut -d'/' -f3- -; } 2>&1 )
    # echo status for calling function to capture
    echo "$output"
    return
}

fetch_checkout_pull_branch() {
    # Check out specified branch
    local directory
    directory="${1}"
    local branch
    branch="${2}"

    # Set the reference for the requested branch, fetch, check it put and pull it
    cd "${directory}" || return 1
    git remote set-branches origin "${branch}" || return 1
    git stash --all --quiet &> /dev/null || true
    git clean --quiet --force -d || true
    git fetch --quiet || return 1
    checkout_pull_branch "${directory}" "${branch}" || return 1
}

checkout_pull_branch() {
    # Check out specified branch
    local directory
    directory="${1}"
    local branch
    branch="${2}"
    local oldbranch

    cd "${directory}" || return 1

    oldbranch="$(git symbolic-ref HEAD)"

    str="Switching to branch: '${branch}' from '${oldbranch}'"
    printf "  %b %s" "${INFO}" "$str"
    git checkout "${branch}" --quiet || return 1
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "$str"
    # Data in the repositories is public anyway so we can make it readable by everyone (+r to keep executable permission if already set by git)
    chmod -R a+rX "${directory}"

    git_pull=$(git pull || return 1)

    if [[ "$git_pull" == *"up-to-date"* ]]; then
        printf "  %b %s\\n" "${INFO}" "${git_pull}"
    else
        printf "%s\\n" "$git_pull"
    fi

    return 0
}

clone_or_update_repos() {
    # so get git files for Core
    getGitFiles "${PIKONEK_LOCAL_REPO}/pikonek" ${pikonekGitUrl} || \
    { printf "  %bUnable to clone %s into %s, unable to continue%b\\n" "${COL_LIGHT_RED}" "${pikonekGitUrl}" "${PIKONEK_LOCAL_REPO}" "${COL_NC}"; \
    exit 1; \
    }
    # get git files for config
    getGitFiles "${PIKONEK_LOCAL_REPO}/configs" ${pikonekGitConfig} || \
    { printf "  %bUnable to clone %s into %s, unable to continue%b\\n" "${COL_LIGHT_RED}" "${pikonekGitConfig}" "${PIKONEK_LOCAL_REPO}" "${COL_NC}"; \
    exit 1; \
    }
    # get git files for scripts
    getGitFiles "${PIKONEK_LOCAL_REPO}/scripts" ${pikonekGitScripts} || \
    { printf "  %bUnable to clone %s into %s, unable to continue%b\\n" "${COL_LIGHT_RED}" "${pikonekGitScripts}" "${PIKONEK_LOCAL_REPO}" "${COL_NC}"; \
    exit 1; \
    }
    # get git files for packages
    getGitFiles "${PIKONEK_LOCAL_REPO}/packages" ${pikonekGitPackages} || \
    { printf "  %bUnable to clone %s into %s, unable to continue%b\\n" "${COL_LIGHT_RED}" "${pikonekGitPackages}" "${PIKONEK_LOCAL_REPO}" "${COL_NC}"; \
    exit 1; \
    }
    # get git files for packages
    getGitFiles "${PIKONEK_LOCAL_REPO}/blocked" ${pikonekGitBlockedList} || \
    { printf "  %bUnable to clone %s into %s, unable to continue%b\\n" "${COL_LIGHT_RED}" "${pikonekGitPackages}" "${PIKONEK_LOCAL_REPO}" "${COL_NC}"; \
    exit 1; \
    }
}

make_temporary_log() {
    # Create a random temporary file for the log
    TEMPLOG=$(mktemp /tmp/pikonek_temp.XXXXXX)
    # Open handle 3 for templog
    # https://stackoverflow.com/questions/18460186/writing-outputs-to-log-file-and-console
    exec 3>"$TEMPLOG"
    # Delete templog, but allow for addressing via file handle
    # This lets us write to the log without having a temporary file on the drive, which
    # is meant to be a security measure so there is not a lingering file on the drive during the install process
    rm "$TEMPLOG"
}

copy_to_install_log() {
    # Copy the contents of file descriptor 3 into the install log
    # Since we use color codes such as '\e[1;33m', they should be removed
    sed 's/\[[0-9;]\{1,5\}m//g' < /proc/$$/fd/3 > "${installLogLoc}"
    chmod 644 "${installLogLoc}"
}

main() {
    ######## FIRST CHECK ########
    # Must be root to install
    local str="Root user check"
    printf "\\n"

    # If the user's id is zero,
    if [[ "${EUID}" -eq 0 ]]; then
        # they are root and all is good
        printf "  %b %s\\n" "${TICK}" "${str}"
        # Show the PiKonek logo so people know it's genuine since the logo and name are trademarked
        show_ascii_berry
        make_temporary_log
    # Otherwise,
    else
        # They do not have enough privileges, so let the user know
        printf "  %b %s\\n" "${CROSS}" "${str}"
        printf "  %b %bScript called with non-root privileges%b\\n" "${INFO}" "${COL_LIGHT_RED}" "${COL_NC}"
        printf "      The PiKonek requires elevated privileges to install and run\\n"
        printf "      Please check the installer for any concerns regarding this requirement\\n"
        printf "      Make sure to download this script from a trusted source\\n\\n"
        printf "  %b Sudo utility check" "${INFO}"

        # If the sudo command exists,
        if is_command sudo ; then
            printf "%b  %b Sudo utility check\\n" "${OVER}"  "${TICK}"
            # Download the install script and run it with admin rights
            # TODO: Set the install url
            # exec curl -sSL https://raw.githubusercontent.com/PiKonek/PiKonek/master/automated%20install/basic-install.sh | sudo bash "$@"
            exit $?
        # Otherwise,
        else
            # Let them know they need to run it as root
            printf "%b  %b Sudo utility check\\n" "${OVER}" "${CROSS}"
            printf "  %b Sudo is needed to run pikonek commands\\n\\n" "${INFO}"
            printf "  %b %bPlease re-run this installer as root${COL_NC}\\n" "${INFO}" "${COL_LIGHT_RED}"
            exit 1
        fi
    fi

    # Check for supported distribution
    distro_check

    # Start the installer
    # Verify there is enough disk space for the install
    if [[ "${skipSpaceCheck}" == true ]]; then
        printf "  %b Skipping free disk space verification\\n" "${INFO}"
    else
        verifyFreeDiskSpace
    fi

    uninstall

    # Notify user of package availability
    notify_package_updates_available

    # Install packages used by this installation script
    install_dependent_packages "${INSTALLER_DEPS[@]}"

    # Check that the installed OS is officially supported - display warning if not
    os_check

    # Check if SELinux is Enforcing
    checkSelinux

    # Disable predictable names
    do_net_names

    # Display welcome dialogs
    welcomeDialogs
    # Create directory for PiKonek storage
    install -d -m 755 /etc/pikonek/
    # Clone/Update the repos
    clone_or_update_repos
    # Determine available interfaces
    get_available_interfaces
    get_available_wlan_interfaces
    # Set up wan interface
    setupWanInterface
    # Set up lan interface
    setupLanInterface
    # Decide what upstream DNS Servers to use
    setupWlanInterface
    # setDns
    setDNS
    # Install the Core dependencies
    pip_install_packages
    # On some systems, lighttpd is not enabled on first install. We need to enable it here if the user
    # has chosen to install the web interface, else the `LIGHTTPD_ENABLED` check will fail
    enable_service lighttpd
    # Determine if lighttpd is correctly enabled
    if check_service_active "lighttpd"; then
        LIGHTTPD_ENABLED=true
    else
        LIGHTTPD_ENABLED=false
    fi
    # Create the pikonek user
    create_pikonek_user

    # Install and log everything to a file
    installpikonek | tee -a /proc/$$/fd/3
    
    finalExports
    # configure the dhcp and dns
    configureDhcp
    # configure the network interface
    configureNetwork
    # configure wireless access point
    if [ "$WLAN_AP" -eq 1 ]; then
        configureWirelessAP
    fi
    # Copy the temp log file into final log location for storage
    copy_to_install_log
    # Add password to web UI if there is none
    pw=""
    # If no password is set,
    if [[ $(grep 'WEBPASSWORD' -c /etc/pikonek/setupVars.conf) == 0 ]] ; then
        # generate a random password
        pw=$(tr -dc _A-Z-a-z-0-9 < /dev/urandom | head -c 8)
        # shellcheck disable=SC1091
        pikonek -p "${pw}"
        echo "WEBPASSWORD=${pw}" >> "${setupVars}"
    fi

    if [[ "${LIGHTTPD_ENABLED}" == true ]]; then
        restart_service lighttpd
        enable_service lighttpd
    else
        printf "  %b Lighttpd is disabled, skipping service restart\\n" "${INFO}"
    fi

    printf "  %b Restarting services...\\n" "${INFO}"
    # Start services

    displayFinalMessage "${pw}"
    if (( ${#pw} > 0 )) ; then
        # display the password
        printf "  %b Web Interface password: %b%s%b\\n" "${INFO}" "${COL_LIGHT_GREEN}" "${pw}" "${COL_NC}"
        printf "  %b This can be changed using 'pikonek -p'\\n\\n" "${INFO}"
    fi

    printf "  %b View the web interface at http://pi.konek/ or http://%s/\\n\\n" "${INFO}" "${LAN_IPV4_ADDRESS%/*}"
    printf "  %b Please reboot your system.\\n" "${INFO}"
    INSTALL_TYPE="Installation"

    # Display where the log file is
    printf "\\n  %b The install log is located at: %s\\n" "${INFO}" "${installLogLoc}"
    printf "%b%s Complete! %b\\n" "${COL_LIGHT_GREEN}" "${INSTALL_TYPE}" "${COL_NC}"
}

if [[ "${PH_TEST}" != true ]] ; then
    main "$@"
fi
