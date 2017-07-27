#!/bin/bash

NODENAME=$(hostname)

MOUNTPOINT="/datadrive"
RAIDCHUNKSIZE=512

RAIDDISK="/dev/md127"
RAIDPARTITION="/dev/md127p1"
# A set of disks to ignore from partitioning and formatting
BLACKLIST="/dev/sda|/dev/sdb"

check_os() {
    grep ubuntu /proc/version > /dev/null 2>&1
    isubuntu=${?}
    grep centos /proc/version > /dev/null 2>&1
    iscentos=${?}
}

scan_for_new_disks() {
    # Looks for unpartitioned disks
    declare -a RET
    DEVS=($(ls -1 /dev/sd*|egrep -v "${BLACKLIST}"|egrep -v "[0-9]$"))
    for DEV in "${DEVS[@]}";
    do
        # Check each device if there is a "1" partition.  If not,
        # "assume" it is not partitioned.
        if [ ! -b ${DEV}1 ];
        then
            RET+="${DEV} "
        fi
    done
    echo "${RET}"
}

get_disk_count() {
    DISKCOUNT=0
    for DISK in "${DISKS[@]}";
    do
        DISKCOUNT+=1
    done;
    echo "$DISKCOUNT"
}

create_raid0_ubuntu() {
    declare -a PARTITIONS
    for DISK in "${DISKS[@]}";
    do
        echo "Creating RAID partition in ${DISK}."
        # Partition the disks.
        parted --align optimal --script "${DISK}" \
            mklabel gpt \
            mkpart primary 0% 100% \
            set 1 raid on

        PARTITIONS+="${DISK}1 "
    done;
    DISK_PARTITIONS=($(echo "${PARTITIONS}"))
    echo "Partitions are ${DISK_PARTITIONS[@]}"

    dpkg -s mdadm

    if [ ${?} -eq 1 ];
    then
        echo "installing mdadm"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get -q -y install mdadm --no-install-recommends
    fi

    echo "Creating raid0"
    udevadm control --stop-exec-queue

    echo "yes" | mdadm --create "$RAIDDISK" --name=data --level=0 --chunk="$RAIDCHUNKSIZE" --raid-devices="$DISKCOUNT" "${DISK_PARTITIONS[@]}"
    udevadm control --start-exec-queue
    mdadm --detail --verbose --scan > /etc/mdadm.conf
}

create_raid0_centos() {
    echo "Creating raid0"
    yes | mdadm --create "$RAIDDISK" --name=data --level=0 --chunk="$RAIDCHUNKSIZE" --raid-devices="$DISKCOUNT" "${DISKS[@]}"
    mdadm --detail --verbose --scan > /etc/mdadm.conf
}

do_partition() {
    # This function creates one (1) primary partition on the
    # disk, using all available space
    DISK=${1}
    echo "Partitioning disk $DISK"

    parted --align optimal --script "${DISK}" \
        mklabel gpt \
        mkpart primary 0% 100%
    #> /dev/null 2>&1

    #
    if [ ${?} -ne 0 ];
    then
        echo "An error occurred partitioning ${DISK}" >&2
        echo "I cannot continue" >&2
        exit 2
    fi
}

add_to_fstab() {
    UUID=${1}
    MOUNTPOINT=${2}
    grep "${UUID}" /etc/fstab >/dev/null 2>&1
    if [ ${?} -eq 0 ];
    then
        echo "Not adding ${UUID} to fstab again (it's already there!)"
    else
        LINE="UUID=${UUID} ${MOUNTPOINT} xfs defaults,noatime 0 2"
        echo -e "${LINE}" >> /etc/fstab
    fi
}

configure_disks() {
    ls "${MOUNTPOINT}"
    if [ ${?} -eq 0 ]
    then
        return
    fi
    DISKS=($(scan_for_new_disks))
    echo "Disks are ${DISKS[@]}"
    declare -i DISKCOUNT
    DISKCOUNT=$(get_disk_count)
    echo "Disk count is $DISKCOUNT"
    if [ $DISKCOUNT -gt 1 ];
    then
        if [ $iscentos -eq 0 ];
        then
            create_raid0_centos
        elif [ $isubuntu -eq 0 ];
        then
            create_raid0_ubuntu
        fi
        do_partition ${RAIDDISK}
        PARTITION="${RAIDPARTITION}"
    else
      DISK="${DISKS[0]}"
      do_partition ${DISK}
      PARTITION=$(fdisk -l ${DISK}|grep -A 1 Device|tail -n 1|awk '{print $1}')
    fi

    echo "Creating filesystem on ${PARTITION}."
    apt-get update
    apt-get -q -y install xfsprogs
    mkfs.xfs -f ${PARTITION}
    mkdir "${MOUNTPOINT}"
    read UUID FS_TYPE < <(blkid -u filesystem ${PARTITION}|awk -F "[= ]" '{print $3" "$5}'|tr -d "\"")
    add_to_fstab "${UUID}" "${MOUNTPOINT}"
    echo "Mounting disk ${PARTITION} on ${MOUNTPOINT}"
    mount "${MOUNTPOINT}"
}

check_os
if [ $iscentos -ne 0 ] && [ $isubuntu -ne 0 ];
then
    echo "unsupported operating system"
    exit 1
else
    configure_disks
fi
