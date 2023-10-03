#!/usr/bin/env bash
#-----------------------------------------------------------------------------------
# Create volume on M.2 drive(s) on Synology models that don't have a GUI option
#
# Github: https://github.com/maximelapointe/Synology_M2_volume
# Tested on DSM DSM 7.2-64570 Update 3
#
# To run in a shell (replace /volume1/scripts/ with path to script):
# sudo /volume1/scripts/create_m2_volume.sh
#
# Resources:
# https://academy.pointtosource.com/synology/synology-ds920-nvme-m2-ssd-volume/amp/
# https://www.reddit.com/r/synology/comments/pwrch3/how_to_create_a_usable_poolvolume_to_use_as/
#
# Over-Provisioning unnecessary on modern SSDs (since ~2014)
# https://easylinuxtipsproject.blogspot.com/p/ssd.html#ID16.2
#-----------------------------------------------------------------------------------

# Added support for RAID 5
# Changed to not include the 1st selected drive in the choices for 2nd drive etc.
#
# Check for errors from synopartition, mdadm, pvcreate and vgcreate 
#   so the script doesn't continue and appear to have succeeded.
#
# Changed "pvcreate" to "pvcreate -ff" to avoid issues.
#
# Added single progress bar for the resync progress.
#
# Added options:
#  -a, --all        List all M.2 drives even if detected as active
#  -s, --steps      Show the steps to do after running this script
#  -h, --help       Show this help message
#  -v, --version    Show the script version
#
# Added -s, --steps option to show required steps after running script.
#
# Changed for DSM 7.2 and older DSM version:
# - For DSM 7.x
#   - Ensures m2 volume support is enabled.
#   - Creates RAID and storage pool only.
#
# Instead of creating the filesystem directly on the mdraid device, you can use LVM to create a PV on it,
# and a VG, and then use the UI to create volume(s), making it more "standard" to what DSM would do.
# https://systemadmintutorial.com/how-to-configure-lvm-in-linuxpvvglv/
#
# Physical Volume (PV): Consists of Raw disks or RAID arrays or other storage devices.
# Volume Group (VG): Combines the physical volumes into storage groups.
# Logical Volume (LV): VG's are divided into LV's and are mounted as partitions.




#================== Prechecks and gathering variables ==================

#--------------------------------------------------------------------
# User defined variables
raid="RAID 1"

#================== Gathering Variables ==================
# Get DSM major and minor versions
dsm=$(get_key_value /etc.defaults/VERSION majorversion)
dsminor=$(get_key_value /etc.defaults/VERSION minorversion)

# Get NAS model
model=$(cat /proc/sys/kernel/syno_hw_version)

# Check BASH variable is bash
if [ ! "$(basename "$BASH")" = bash ]; then
    echo "This is a bash script. Do not run it with $(basename "$BASH")"
    exit 1
fi

# Check script is running as root
if [[ $( whoami ) != "root" ]]; then
    echo -e "${Error}ERROR${Off} This script must be run as sudo or root!"
    exit 1
fi

# Check DSM 7 or higher
if [[ ! $dsm -gt "6" ]]; then
    echo -e "${Error}ERROR${Off} This script only works with DSM 7 or higher!"
    exit 1
fi


#echo -e "bash version: $(bash --version | head -1 | cut -d' ' -f4)\n"  # debug

# Shell Colors
#Black='\e[0;30m'   # ${Black}
Red='\e[0;31m'      # ${Red}
#Green='\e[0;32m'   # ${Green}
#Yellow='\e[0;33m'  # ${Yellow}
#Blue='\e[0;34m'    # ${Blue}
#Purple='\e[0;35m'  # ${Purple}
Cyan='\e[0;36m'     # ${Cyan}
#White='\e[0;37m'   # ${White}
Error='\e[41m'      # ${Error}
Off='\e[0m'         # ${Off}



usage(){
    cat <<EOF

Usage: $(basename "$0") [options]

Options:
  -a, --all        List all M.2 drives even if detected as active
  -s, --steps      Show the steps to do after running this script
  -h, --help       Show this help message
  -v, --version    Show the script version

EOF
    exit 0
}




createpartition(){
    if [[ $1 ]]; then
        echo -e "\nCreating Synology partitions on $1" >&2
        if ! synopartition --part /dev/"$1" "$synopartindex"; then
            echo -e "\n${Error}ERROR 5${Off} Failed to create syno partitions!" >&2
            exit 1
        fi
    fi
}


selectdisk(){
    if [[ ${#m2list[@]} -gt "0" ]]; then
        select nvmes in "${m2list[@]}" "Done"; do
            case "$nvmes" in
                Done)
                    Done="yes"
                    selected_disk=""
                    break
                    ;;
                Quit)
                    exit
                    ;;
                nvme*)
                    #if [[ " ${m2list[*]} "  =~ " ${nvmes} " ]]; then
                        selected_disk="$nvmes"
                        break
                    #else
                    #    echo -e "${Red}Invalid answer!${Off} Try again." >&2
                    #    selected_disk=""
                    #fi
                    ;;
                *)
                    echo -e "${Red}Invalid answer!${Off} Try again." >&2
                    selected_disk=""
                    ;;
            esac
        done

        if [[ $Done != "yes" ]] && [[ $selected_disk ]]; then
            mdisk+=("$selected_disk")
            # Remove selected drive from list of selectable drives
            remelement "$selected_disk"
            # Keep track of many drives user selected
            selected="$((selected +1))"
            echo -e "You selected ${Cyan}$selected_disk${Off}" >&2

            #echo "Drives selected: $selected" >&2  # debug
        fi
        echo
    else
        Done="yes"
    fi
}


showsteps(){
    echo -e "\n${Cyan}Steps you need to do after running this script:${Off}" >&2
    major=$(get_key_value /etc.defaults/VERSION major)
    if [[ $major -gt "6" ]]; then
        cat <<EOF
  1. After the restart go to Storage Manager and select online assemble:
       Storage Pool > Available Pool > Online Assemble
  2. Create the volume as you normally would:
       Select the new Storage Pool > Create > Create Volume
  3. Optionally enable TRIM:
       Storage Pool > ... > Settings > SSD TRIM
EOF
    echo -e "     ${Cyan}SSD TRIM option is only available in DSM 7.2 Beta for RAID 1${Off}" >&2
    echo -e "\n${Error}Important${Off}" >&2
    cat <<EOF
If you later upgrade DSM and your M.2 drives are shown as unsupported
and the storage pool is shown as missing, and online assemble fails,
you should run the Synology HDD db script:
EOF
    echo -e "${Cyan}https://github.com/007revad/Synology_HDD_db${Off}\n" >&2
    fi
    #return
}


#================== Begin script ==================




#================== Inferring Settings ==================
if [[ $dsm -gt "6" ]] && [[ $dsminor -gt "1" ]]; then
    dsm72="yes"
fi
if [[ $dsm -gt "6" ]] && [[ $dsminor -gt "0" ]]; then
    dsm71="yes"
fi


================== TO DELETE AFTER CLEANING (/start) ==================
# Check for flags with getopt
if options="$(getopt -o abcdefghijklmnopqrstuvwxyz0123456789 -a -l all,steps,help -- "$@")"; then
    eval set -- "$options"
    while true; do
        case "${1,,}" in
            -s|--steps)         # Show steps remaining after running script
                showsteps
                exit
                ;;
            -h|--help)          # Show usage options
                usage
                ;;
            --)
                shift
                break
                ;;
            *)                  # Show usage options
                echo -e "Invalid option '$1'\n"
                usage "$1"
                ;;
        esac
        shift
    done
else
    echo
    usage
fi

================== TO DELETE AFTER CLEANING (/end) ==================



#--------------------------------------------------------------------
# Put a pause in case of regrets
echo -e "Type ${Cyan}anything${Off} to continue."
read -r answer
echo


#--------------------------------------------------------------------
# Check there's no active resync

if grep resync /proc/mdstat >/dev/null ; then
    echo "The Synology is currently doing a RAID resync or data scrub!"
    exit
fi


#--------------------------------------------------------------------
# Get list of all M.2 drives

getallm2info() {
    nvmemodel=$(cat "$1/device/model")
    nvmemodel=$(printf "%s" "$nvmemodel" | xargs)  # trim leading/trailing space
    echo "$2 M.2 $(basename -- "${1}") is $nvmemodel" >&2

    dev="$(basename -- "${1}")"
    if [[ -e /dev/${dev}p1 ]] && [[ -e /dev/${dev}p2 ]] && [[ -e /dev/${dev}p3 ]]; then
        echo -e "${Cyan}WARNING Drive has a volume partition${Off}" >&2
        haspartitons="yes"
    elif [[ ! -e /dev/${dev}p3 ]] && [[ ! -e /dev/${dev}p2 ]] && [[ -e /dev/${dev}p1 ]]; then
        echo -e "${Cyan}WARNING Drive has a cache partition${Off}" >&2
        haspartitons="yes"
    elif [[ ! -e /dev/${dev}p3 ]] && [[ ! -e /dev/${dev}p2 ]] && [[ ! -e /dev/${dev}p1 ]]; then
        echo "No existing partitions on drive" >&2
    fi
    m2list+=("${dev}")
    echo "" >&2
}

for d in /sys/block/*; do
    case "$(basename -- "${d}")" in
        nvme*)  # M.2 NVMe drives
            if [[ $d =~ nvme[0-9][0-9]?n[0-9][0-9]?$ ]]; then
                getallm2info "$d" "NVMe"
            fi
        ;;
        nvc*)  # M.2 SATA drives (in PCIe card only?)
            if [[ $d =~ nvc[0-9][0-9]?$ ]]; then
                getallm2info "$d" "SATA"
            fi
        ;;
        *)
        ;;
    esac
done

echo -e "NVMe list: ${m2list[@]}\n"
echo -e "NVMe qty: ${#m2list[@]}\n"

#--------------------------------------------------------------------
# Set storage pool mode (Single or RAID if multiple M.2 drives found)

if [[ ${#m2list[@]} == "0" ]]; then
    echo "No NVME drive"
    exit
elif [[ ${#m2list[@]} -eq "1" ]]; then
    raidtype="1"
    single="yes"
elif [[ ${#m2list[@]} -gt "1" ]]; then
    case "$raid" in
        "Single")
            raidtype="1"
            single="yes"
            mindisk=1
            #maxdisk=1
            break
            ;;
        "RAID 0")
            raidtype="0"
            mindisk=2
            #maxdisk=24
            break
        ;;
        "RAID 1")
            raidtype="1"
            mindisk=2
            #maxdisk="${#m2list[@]}"
            break
        ;;
        *)
            echo -e "${Red}Invalid raid value!${Off} Try again."
        ;;
    esac
fi


if [[ $single == "yes" ]]; then
    maxdisk=1
elif [[ $raidtype == "1" ]]; then
    maxdisk=4
#else
    # Only Basic and RAID 1 have a limit on the number of drives in DSM 7 and 6
    # Later we set maxdisk to the number of M.2 drives found if not Single or RAID 1
#    maxdisk=24
fi


#--------------------------------------------------------------------
# Select M.2 drives

getindex(){
    # Get array index from value
    for i in "${!m2list[@]}"; do
        if [[ "${m2list[$i]}" == "${1}" ]]; then
            r="${i}"
        fi
    done
    return "$r"
}

remelement(){
    # Remove selected drive from list of other selectable drives
    if [[ $1 ]]; then
        num="0"
        while [[ $num -lt "${#m2list[@]}" ]]; do
            if [[ ${m2list[num]} == "$1" ]]; then
                # Remove selected drive from m2list array
                unset "m2list[num]"

                # Rebuild the array to remove empty indices
                for i in "${!m2list[@]}"; do
                    tmp_array+=( "${m2list[i]}" )
                done
                m2list=("${tmp_array[@]}")
                unset tmp_array
            fi
            num=$((num +1))
        done
    fi
}

mdisk=(  )

# Set maxdisk to the number of M.2 drives found if not Single or RAID 1
# Only Basic and RAID 1 have a limit on the number of drives in DSM 7 and 6
if [[ $single != "yes" ]] && [[ $raidtype != "1" ]]; then
    maxdisk="${#m2list[@]}"
fi

while [[ $selected -lt "$mindisk" ]] || [[ $selected -lt "$maxdisk" ]]; do
    if [[ $single == "yes" ]]; then
        PS3="Select the M.2 drive: "
    else
        PS3="Select the M.2 drive #$((selected+1)): "
    fi
    selectdisk
    if [[ $Done == "yes" ]]; then
        break
    fi
done

if [[ $selected -lt "$mindisk" ]]; then
    echo "Drives selected: $selected"
    echo -e "${Error}ERROR${Off} You need to select $mindisk or more drives for RAID $raidtype"
    exit
fi

#--------------------------------------------------------------------
# Confirm choices

echo -en "Ready to create ${Cyan}RAID $raidtype${Off} volume group using "
echo -e "${Cyan}${mdisk[*]}${Off}"

if [[ $haspartitons == "yes" ]]; then
    echo -e "\n${Red}WARNING${Off} Everything on the selected"\
        "M.2 drive(s) will be deleted."
fi

echo -e "Type ${Cyan}yes${Off} to continue. Type anything else to quit."
read -r answer
if [[ ${answer,,} != "yes" ]]; then exit; fi

echo -e "Confirmed\n"
sleep 1

#--------------------------------------------------------------------
# Get highest md# mdraid device

# Using "md[0-9]{1,2}" to avoid md126 and md127 etc
lastmd=$(grep -oP "md[0-9]{1,2}" "/proc/mdstat" | sort | tail -1)
nextmd=$((${lastmd:2} +1))
if [[ -z $nextmd ]]; then
    echo -e "${Error}ERROR${Off} Next md number not found!"
    exit 1
else
    echo "Using md$nextmd as it's the next available."
fi

#--------------------------------------------------------------------
# Create Synology partitions on selected M.2 drives

synopartindex=13  # Syno partition index for NVMe drives can be 12 or 13 or ?

partargs=(  )
for i in "${mdisk[@]}"
do
   :
   createpartition "$i"
   partargs+=(
       /dev/"${i}"p3
   )
done


#--------------------------------------------------------------------
# Create the RAID array
# --level=0 for RAID 0  --level=1 for RAID 1  --level=5 for RAID 5
SECONDS=0  # To work out how long the resync took

echo -e "\nCreating the RAID array. This will take a while..."

if ! mdadm --create /dev/md"${nextmd}" --level="${raidtype}" --raid-devices="$selected" --force "${partargs[@]}"; then
    echo -e "\n${Error}ERROR 5${Off} Failed to create RAID!"
    exit 1
fi

# Show resync progress every 5 seconds
while grep resync /proc/mdstat >/dev/null; do
    # Only multi-drive RAID gets re-synced
    progress="$(grep -E -A 2 active.*nvme /proc/mdstat | grep resync | cut -d\( -f1 )"
    echo -ne "$progress\r"
    sleep 5
done
# Show 100% progress
if [[ $progress ]]; then
    echo -ne "      [====================>]  resync = 100%\r"
fi

# Show how long the resync took
end=$SECONDS
if [[ $end -ge 3600 ]]; then
    printf '\nResync Duration: %d hr %d min\n' $((end/3600)) $((end%3600/60))
elif [[ $end -ge 60 ]]; then
    echo -e "\nResync Duration: $(( end / 60 )) min"
else
    echo -e "\nResync Duration: $end sec"
fi


#--------------------------------------------------------------------
# Create Physical Volume and Volume Group with LVM

# Create a physical volume (PV) on the partition
echo -e "\nCreating a physical volume (PV) on md$nextmd partition"
if ! pvcreate -ff /dev/md$nextmd ; then
    echo -e "\n${Error}ERROR 5${Off} Failed to create physical volume!"
    exit 1
fi

# Create a volume group (VG)
echo -e "\nCreating a volume group (VG) on md$nextmd partition"
if ! vgcreate vg$nextmd /dev/md$nextmd ; then
    echo -e "\n${Error}ERROR 5${Off} Failed to create volume group!"
    exit 1
fi


#--------------------------------------------------------------------
# Enable m2 volume support - DSM 7.1 and later only

# Backup synoinfo.conf if needed
#if [[ $dsm72 == "yes" ]]; then
if [[ $dsm71 == "yes" ]]; then
    synoinfo="/etc.defaults/synoinfo.conf"
    if [[ ! -f ${synoinfo}.bak ]]; then
        if cp "$synoinfo" "$synoinfo.bak"; then
            echo -e "\nBacked up $(basename -- "$synoinfo")" >&2
        else
            echo -e "\n${Error}ERROR 5${Off} Failed to backup $(basename -- "$synoinfo")!"
            exit 1
        fi
    fi
fi

# Check if m2 volume support is enabled
#if [[ $dsm72 == "yes" ]]; then
if [[ $dsm71 == "yes" ]]; then
    smp=support_m2_pool
    setting="$(get_key_value "$synoinfo" "$smp")"
    enabled=""
    if [[ ! $setting ]]; then
        # Add support_m2_pool="yes"
        echo 'support_m2_pool="yes"' >> "$synoinfo"
        enabled="yes"
    elif [[ $setting == "no" ]]; then
        # Change support_m2_pool="no" to "yes"
        #sed -i "s/${smp}=\"no\"/${smp}=\"yes\"/" "$synoinfo"
        synosetkeyvalue "$synoinfo" "$smp" "yes"
        enabled="yes"
    elif [[ $setting == "yes" ]]; then
        echo -e "\nM.2 volume support already enabled."
    fi

    # Check if we enabled m2 volume support
    setting="$(get_key_value "$synoinfo" "$smp")"
    if [[ $enabled == "yes" ]]; then
        if [[ $setting == "yes" ]]; then
            echo -e "\nEnabled M.2 volume support."
        else
            echo -e "\n${Error}ERROR${Off} Failed to enable m2 volume support!"
        fi
    fi
fi



#--------------------------------------------------------------------
# Reboot and quit+
#--------------------------------------------------------------------
#
echo "Rebooting"
reboot

echo -e "Type anything to quit"
read -r answer
exit
