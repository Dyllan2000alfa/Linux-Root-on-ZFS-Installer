#!/bin/bash

##
# Disk Variables
##

diskDev=()
vdev_type=mirror
INST_PARTSIZE_SWAP=8
INST_PARTSIZE_RPOOL=
name="fedora"
encryption=false
lts=false
vgpu_merged=false
user=
password=
hostname=
locale="en/us"
keymap="en/us"
timezone="America/Chicago"

##
# Color  Variables
##

green='\e[32m'
blue='\e[34m'
clear='\e[0m'

##
# Color Functions
##

ColorGreen(){
	echo -ne $green$1$clear
}
ColorBlue(){
	echo -ne $blue$1$clear
}

##
# Installation Functions
##

function setup_live() {
    setenforce 0
    dnf install -y https://zfsonlinux.org/fedora/zfs-release-2-2$(rpm --eval "%{dist}").noarch.rpm
    rpm -e --nodeps zfs-fuse
    dnf install -y https://dl.fedoraproject.org/pub/fedora/linux/releases/$(source /etc/os-release; echo $VERSION_ID)/Everything/x86_64/os/Packages/k/kernel-devel-$(uname -r).rpm
    dnf install -y zfs
    modprobe zfs
    dnf install -y gdisk dosfstools
}

function partition_disks() {
    for i in ${DISK}; do

    sgdisk --zap-all $i

    sgdisk -n1:1M:+1G -t1:EF00 $i

    sgdisk -n2:0:+4G -t2:BE00 $i

    test -z $INST_PARTSIZE_SWAP || sgdisk -n4:0:+${INST_PARTSIZE_SWAP}G -t4:8200 $i

    if test -z $INST_PARTSIZE_RPOOL; then
        sgdisk -n3:0:0   -t3:BF00 $i
    else
        sgdisk -n3:0:+${INST_PARTSIZE_RPOOL}G -t3:BF00 $i
    fi

    sgdisk -a1 -n5:24K:+1000K -t5:EF02 $i
    done
}

function create_bpool() {
    zpool create \
    -o compatibility=grub2 \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl \
    -O canmount=off \
    -O compression=lz4 \
    -O devices=off \
    -O normalization=formD \
    -O relatime=on \
    -O xattr=sa \
    -O mountpoint=/boot \
    -R /mnt \
    bpool \
    $vdev_type \
    $(for i in ${DISK}; do
       printf "$i-part2 ";
      done)
}

function create_rpool() {
    zpool create \
    -o ashift=12 \
    -o autotrim=on \
    -R /mnt \
    -O acltype=posixacl \
    -O canmount=off \
    -O compression=zstd \
    -O dnodesize=auto \
    -O normalization=formD \
    -O relatime=on \
    -O xattr=sa \
    -O mountpoint=/ \
    rpool \
    $vdev_type \
   $(for i in ${DISK}; do
      printf "$i-part3 ";
     done)
}

function unencrypted_root() {
    zfs create \
     -o canmount=off \
     -o mountpoint=none \
     rpool/$name
}

function encrypted_root() {
    zfs create \
     -o canmount=off \
     -o mountpoint=none \
     -o encryption=on \
     -o keylocation=prompt \
     -o keyformat=passphrase \
     rpool/$name
}

function create_datasets() {
    zfs create -o canmount=on -o mountpoint=/     rpool/$name/root
    zfs create -o canmount=on -o mountpoint=/home rpool/$name/home
    zfs create -o canmount=off -o mountpoint=/var  rpool/$name/var
    zfs create -o canmount=on  rpool/$name/var/lib
    zfs create -o canmount=on  rpool/$name/var/log 

    zfs create -o canmount=off -o mountpoint=none bpool/$name
    zfs create -o canmount=on -o mountpoint=/boot bpool/$name/root
}

function create_esp() {
    for i in ${DISK}; do
     mkfs.vfat -n EFI ${i}-part1
     mkdir -p /mnt/boot/efis/${i##*/}-part1
     mount -t vfat ${i}-part1 /mnt/boot/efis/${i##*/}-part1
    done

    mkdir -p /mnt/boot/efi
    mount -t vfat $(echo $DISK | cut -f1 -d\ )-part1 /mnt/boot/efi
}

function install_packages() {
    dnf --installroot=/mnt   --releasever=$(source /etc/os-release ; echo $VERSION_ID) -y install \
    @core  grub2-efi-x64 grub2-pc-modules grub2-efi-x64-modules shim-x64 efibootmgr kernel \
    kernel-devel

    dnf --installroot=/mnt   --releasever=$(source /etc/os-release ; echo $VERSION_ID) -y install \
    https://zfsonlinux.org/fedora/zfs-release-2-2$(rpm --eval "%{dist}").noarch.rpm

    dnf --installroot=/mnt   --releasever=$(source /etc/os-release ; echo $VERSION_ID) -y install zfs zfs-dracut
}

function install_packages_lts() {
    dnf --installroot=/mnt copr enable kwizart/kernel-longterm-5.15
    dnf --installroot=/mnt   --releasever=$(source /etc/os-release ; echo $VERSION_ID) -y install \
    @core  grub2-efi-x64 grub2-pc-modules grub2-efi-x64-modules shim-x64 efibootmgr kernel-longterm \
    kernel-longterm-devel

    dnf --installroot=/mnt   --releasever=$(source /etc/os-release ; echo $VERSION_ID) -y install \
    https://zfsonlinux.org/fedora/zfs-release-2-2$(rpm --eval "%{dist}").noarch.rpm

    dnf --installroot=/mnt   --releasever=$(source /etc/os-release ; echo $VERSION_ID) -y install zfs zfs-dracut
}

function generate_fstab() {
    mkdir -p /mnt/etc/
    for i in ${DISK}; do
        echo UUID=$(blkid -s UUID -o value ${i}-part1) /boot/efis/${i##*/}-part1 vfat \
        umask=0022,fmask=0022,dmask=0022 0 1 >> /mnt/etc/fstab
    done
    echo $(echo $DISK | cut -f1 -d\ )-part1 /boot/efi vfat \
        noauto,umask=0022,fmask=0022,dmask=0022 0 1 >> /mnt/etc/fstab
}

function configure_dracut() {
    echo 'add_dracutmodules+=" zfs "' > /mnt/etc/dracut.conf.d/zfs.conf

    if grep mpt3sas /proc/modules; then
        echo 'forced_drivers+=" mpt3sas "'  >> /mnt/etc/dracut.conf.d/zfs.conf
    fi
}

function setup_system() {
    rm -f /mnt/etc/localtime
    systemd-firstboot --root=/mnt --prompt --root-password=PASSWORD --force --hostname=$hostname --locale=$locale --keymap=$keymap --timezone=$timezone --root-shell=bash
    zgenhostid -f -o /mnt/etc/hostid
    dnf --installroot=/mnt install -y glibc-minimal-langpack glibc-langpack-en
    systemctl enable zfs-import-scan.service zfs-mount zfs-import.target zfs-zed zfs.target --root=/mnt
    systemctl disable sshd --root=/mnt
    systemctl enable firewalld --root=/mnt
}

function chroot_commands() {
    echo -e 'fixfiles -F onboot

    adduser $user -p $c

    usermod -a -G wheel $user

    for directory in /lib/modules/*; do
        kernel_version=$(basename $directory)
        dkms autoinstall -k $kernel_version
    done

    echo 'filesystems+=" virtio_blk "' >> /etc/dracut.conf.d/fs.conf

    rm -f /etc/zfs/zpool.cache
    touch /etc/zfs/zpool.cache
    chmod a-w /etc/zfs/zpool.cache
    chattr +i /etc/zfs/zpool.cache

    for directory in /lib/modules/*; do
        kernel_version=$(basename $directory)
        dracut --force --kver $kernel_version
    done

    echo 'GRUB_ENABLE_BLSCFG=false' >> /etc/default/grub

    echo 'export ZPOOL_VDEV_NAME_PATH=YES' >> /etc/profile.d/zpool_vdev_name_path.sh
    source /etc/profile.d/zpool_vdev_name_path.sh

    # GRUB fails to detect rpool name, hard code as "rpool"
    sed -i "s|rpool=.*|rpool=rpool|"  /etc/grub.d/10_linux

    export ZPOOL_VDEV_NAME_PATH=YES
    mkdir -p /boot/efi/fedora/grub-bootdir/i386-pc/
    mkdir -p /boot/efi/fedora/grub-bootdir/x86_64-efi/
    for i in ${DISK}; do
        grub2-install --target=i386-pc --boot-directory \
            /boot/efi/fedora/grub-bootdir/i386-pc/  $i
    done

    cp -r /usr/lib/grub/x86_64-efi/ /boot/efi/EFI/fedora/

    grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
    grub2-mkconfig -o /boot/efi/fedora/grub-bootdir/i386-pc/grub2/grub.cfg

    ESP_MIRROR=$(mktemp -d)
    unalias -a
    cp -r /boot/efi/EFI $ESP_MIRROR
    for i in /boot/efis/*; do
        cp -r $ESP_MIRROR/EFI $i
    done
    rm -rf $ESP_MIRROR

    exit' > /mnt/root/chroot.sh
}

function chroot_setup() {
    m='/dev /proc /sys'
    for i in $m; do mount --rbind $i /mnt/$i; done

    chroot_commands

    history -w /mnt/home/sys-install-pre-chroot.txt
    chroot /mnt /usr/bin/env \
        user=$user \
        password=$password \
        bash --login /root/chroot.sh
}

function cleanup() {
    umount -Rl /mnt
    zpool export -a
    
    echo "Fedora ZFS has been installed, please reboot"

    exit
}

##
# Configuration Functions
##

function swap_size() {
    echo -ne "How many GB would you like swap to be: "
        read INST_PARTSIZE_SWAP

    partition_size
}

function rpool_size() {
    echo -ne "How many GB would you like swap to be: "
        read INST_PARTSIZE_RPOOL

    partition_size
}

function enabled_disabled() {
    if [ $1 == true ]; then
        echo "Enabled"
    else
        echo "Disabled"
    fi
}

function invert_bool() {
    if [ $1 == true ]; then
        export $2=false
    else
        export $2=true
    fi
}

function change_user() {
    echo -ne "Type new username: "
    read user

    return
}

function change_pass() {
    echo -e "Warning! Password will not be hidden on this screen or the previous"
    echo -ne "Type new password: "
    read password
    
    return
}

function change_hostname() {
    echo -ne "Type new hostname: "
    read hostname
    
    return
}

function change_locale() {
    echo -ne "Type new locale: "
    read locale

    return
}

function change_keymap() {
    echo -ne "Type new keymap: "
    read keymap
    
    return
}

function change_tz() {
    echo -ne "Type new timezone: "
    read timezone
    
    return
}

function devToId() {
    for i in ${diskDev}; do
        diskLine="$(ls -l /dev/disk/by-id/ | grep -v nvme-nvme | grep -m 1 $i)"

        readarray -d " " -t strarr <<< "$diskLine"

        DISK+="/dev/disk/by-id/${strarr[8]}"
    done

    echo $DISK
}

##
# Menu Functions
##

function choose_disks() {
    clear
    disk=()
    size=()
    name=()
    while IFS= read -r -d $'\0' device; do
        device=${device/\/dev\//}
        disk+=($device)
        name+=("`cat "/sys/class/block/$device/device/model"`")
        size+=("`cat "/sys/class/block/$device/size"`")
    done < <(find "/dev/" -regex '/dev/sd[a-z]\|/dev/vd[a-z]\|/dev/hd[a-z]\|/dev/nvme[0-9]n[0-9]' -print0)

    echo -e "   Disk\t\tName"
    for i in `seq 0 $((${#disk[@]}-1))`; do
        
        if [[ "${disk[$i]}" == *"nvme"* ]]; then
            echo -e "$(ColorGreen $(($i+1))\)) ${disk[$i]}\t${name[$i]}"
        else
            echo -e "$(ColorGreen $(($i+1))\)) ${disk[$i]}\t\t${name[$i]}"
        fi
    done
    echo -e "$(ColorGreen '0)') Return"
    echo -e "Selected Disks: $diskDev"
    echo -ne "$(ColorBlue 'Choose Disk(s): ')"
        read a
        if [ "$a" == "0" ]; then
            return
        else
            diskDev+="${disk[$((a - 1))]} "
            choose_disks
        fi
}

function partition_size() {
    clear
    echo -ne "   Change partition size
    $(ColorGreen '1)') Swap Size: $INST_PARTSIZE_SWAP GB
    $(ColorGreen '2)') RPool Size: $INST_PARTSIZE_RPOOL GB (If blank use rest of disk)
    $(ColorGreen '0)') Return
    $(ColorBlue 'Choose an option:') "
        read a
        case $a in
	        1) swap_size ; menu ;;
	        2) rpool_size ; menu ;;
		0) return ;;
		*) echo -e $red"Wrong option."$clear; WrongCommand;;
        esac
}

function vdev_select() {
    clear
    echo -ne "   Choose vdev type (If only a single disk is selceted type will be ignored)
    $(ColorGreen '1)') RAIDz1
    $(ColorGreen '2)') RAIDz2
    $(ColorGreen '3)') RAIDz3
    $(ColorGreen '4)') mirror
    $(ColorGreen '0)') Return
    $(ColorGreen 'Current type:') $vdev_type
    $(ColorBlue 'Choose an option:') "    
        read a
        case $a in
	        1) vdev_type="raidz1" ; vdev_select ;;
	        2) vdev_type="raidz2" ; vdev_select ;;
            3) vdev_type="raidz3" ; vdev_select ;;
            4) vdev_type="mirror" ; vdev_select ;;
		0) return ;;
		*) echo -e $red"Wrong option."$clear; WrongCommand;;
        esac
}

function hostname_user() {
    clear
    echo -ne "   Change partition size
    $(ColorGreen '1)') Username: $user
    $(ColorGreen '2)') Password: $password
    $(ColorGreen '3)') Hostname: $hostname
    $(ColorGreen '4)') Locale: $locale
    $(ColorGreen '5)') Keymap: $keymap
    $(ColorGreen '6)') Timezone: $timezone
    $(ColorGreen '0)') Return
    $(ColorBlue 'Choose an option:') "
        read a
        case $a in
	        1) change_user ; hostname_user ;;
	        2) change_pass ; hostname_user ;;
            3) change_hostname ; hostname_user ;;
            4) change_locale ; hostname_user ;;
            5) change_keymap ; hostname_user ;;
            6) change_tz ; hostname_user ;;
		0) return ;;
		*) echo -e $red"Wrong option."$clear; WrongCommand;;
        esac
}

function system_settings() {
    clear
    echo -ne "   Configure Settings
    $(ColorGreen '1)') Change size of swap and rpool
    $(ColorGreen '2)') Encyption: $(enabled_disabled $encryption) 
    $(ColorGreen '3)') LTS Kernel: $(enabled_disabled $lts)
    $(ColorGreen '4)') Nvidia VGPU Driver: $(enabled_disabled $vgpu_merged)
    $(ColorGreen '5)') Change VDev Type
    $(ColorGreen '6)') Change hostname, user, etc...
    $(ColorGreen '0)') Return
    $(ColorBlue 'Choose an option:') "
        read a
        case $a in
	        1) partition_size ; system_settings ;;
            2) invert_bool $encryption "encryption"; system_settings ;;
            3) invert_bool $lts "lts" ; system_settings ;;
            4) invert_bool $vgpu_merged "vgpu_merged" ; system_settings ;;
            5) vdev_select ; system_settings ;;
            6) hostname_user ; system_settings ;;
		0) return;;
		*) echo -e $red"Wrong option."$clear; WrongCommand;;
        esac
}

function install_fedora() {
    devToId

    if [ $(echo $diskDev | grep -o dev | wc -l) == 1 ]; then
        vdev_type=""
    fi

    echo "Seting up live system for ZFS"
    setup_live

    echo "Clearing and partitioning disk(s)"
    partition_disks

    echo "Creating bpool"
    create_bpool

    echo "Creating rpool"
    create_rpool

    echo "Creating root system container"
    if [ encryption == true ]; then
        encrypted_root
    else
        unencrypted_root
    fi

    echo "Creating datasets"
    create_datasets

    echo "Creating ESP"
    create_esp

    echo "Installing packages"
    if [ lts == true ]; then
        install_packages_lts
    else
        install_packages
    fi

    echo "Generating fstab"
    generate_fstab

    echo "Configuring Dracut"
    configure_dracut

    echo "Setting up system"
    setup_system

    echo "Setting up chroot and running chroot commands"
    chroot_setup

    echo "Cleaning up"
    cleanup
}

##
# Main menu
##

menu(){
clear
echo -ne "   Fedora ZFS Installer
$(ColorGreen '1)') Choose Disk(s)
$(ColorGreen '2)') Configure System
$(ColorGreen '3)') Install Fedora
$(ColorGreen '0)') Exit
$(ColorBlue 'Choose an option:') "
        read a
        case $a in
	        1) choose_disks ; menu ;;
	        2) system_settings ; menu ;;
	        3) install_fedora ; menu ;;
		0) exit 0 ;;
		*) echo -e $red"Wrong option."$clear; WrongCommand;;
        esac
}

menu