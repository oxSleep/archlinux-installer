#!/bin/bash -xe

### Variable ###

hostname="archlazy"
username="sleepy"
user_groups="wheel,audio,video,power,"
LANGUAGE="en_US.UTF-8"

efi_part_sz="260M"
arch="x86_64"

system_app="linux-zen linux-firmware linux-zen-headers base base-devel grub efibootmgr"

user_app="intel-ucode git zip unzip p7zip curl wget xorg-server ttf-dejavu xclip \
    bash-completion dmidecode tmux xdg-utils dbus xdg-desktop-portal-gtk \
    pipewire pipewire-alsa pipewire-pulse wireplumber openssh \
    bspwm sxhkd xorg-xsetroot rofi feh keepassxc libgit2 kitty dhcpcd"

rm_services=()
en_services=("systemd-networkd" "dhcpcd")

### DISK ###
PS3="Select disk for installation: "
select line in $(fdisk -l | grep -v mapper | grep -o '/.*GiB' | tr -d ' '); do
    echo "Selected disk for root: $line"
    DISK_SELECTED=$(echo $line | sed 's/:.*$//')
    break
done

#Check type of disk
if [[ $DISK_SELECTED == *"nvme"* ]]; then
    select l in $(fdisk -l | grep -v mapper | grep -o '/.*GiB' | tr -d ' '); do
        echo "Selected home disk: $l"
        HOME_DISK_SELECTED=$(echo $l | sed 's/:.*$//')
        break
    done
    EFI_PART=$(echo $DISK_SELECTED'p1')
    ROOT_PART=$(echo $DISK_SELECTED'p2')
    HOME_PART=$(echo $HOME_DISK_SELECTED'1')
    system_app="$system_app libvirt qemu-desktop edk2-ovmf virt-manager"
    user_app="$user_app nvidia-open-dkms nvidia-settings"
    en_services="$en_services,libvirtd "
    user_groups="$user_groups,kvm,libvirt"
fi

if [[ $DISK_SELECTED == *"vd"* ]]; then
    EFI_PART=$(echo $DISK_SELECTED'1')
    ROOT_PART=$(echo $DISK_SELECTED'2')
fi

#Wipe disk select
if [[ $DISK_SELECTED == *"nvme"* ]]; then

  wipefs -faq $DISK_SELECTED

  #Format disk as GPT, create EFI partition with size selected above and a 2nd partition with the remaining disk space
  printf 'label: gpt\n, %s, U, *\n, , L\n' "$efi_part_sz" | sfdisk -q "$DISK_SELECTED"

  #Create/mount system partition
  mkfs.ext4  $ROOT_PART
  mkfs.vfat  $EFI_PART
  mount $ROOT_PART /mnt
  mkdir -p /mnt/boot/efi
  mount $EFI_PART /mnt/boot/efi

fi

if [[ $HOME_PART == *"/dev"*  ]]; then
    mkdir -p /mnt/home
    mount $HOME_PART /mnt/home
fi

#Install system package
sed -i '/^#ParallelDownloads/s/.//' /etc/pacman.conf
pacstrap -K /mnt $system_app

#Add hostname and language
echo $hostname > /mnt/etc/hostname
echo "LANG=$LANGUAGE" > /mnt/etc/locale.conf

#Set localtime
chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
arch-chroot /mnt hwclock --systohc

#Generate locale files
sed -i '/^#en_US.UTF-8/s/.//' /mnt/etc/locale.gen
chroot /mnt locale-gen

# Gen fstab
genfstab -U /mnt >> /mnt/etc/fstab


#Install user app
arch-chroot /mnt pacman -S $user_app

sed -i "s/loglevel=3/loglevel=1/" /mnt/etc/default/grub

#Modify GRUB config 
if [[ $system_app == *"qemu"* ]]; then
    kernel_params="intel_iommu=on iommu=pt"
    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$kernel_params /" /mnt/etc/default/grub
fi

# Set bootloader
# Detect if this is an EFI system.
if [ -e /sys/firmware/efi/systab ]; then
    EFI_FW_BITS=$(cat /sys/firmware/efi/fw_platform_size)
    if [ $EFI_FW_BITS -eq 32 ]; then
        EFI_TARGET=i386-efi
    else
        EFI_TARGET=x86_64-efi
    fi
fi

arch-chroot /mnt grub-install --target=$EFI_TARGET --efi-directory=/boot/efi --bootloader-id=Arch --recheck
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg


#Allow users in the wheel group to use sudo
sed -i "s/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL) ALL/" /mnt/etc/sudoers

#Enable services as selected above
for service in ${en_services[@]}; do
		chroot /mnt systemctl enable $service
done

#Create non-root user and add them to group(s)
if [[ $HOME_PART == *"/dev"* ]]; then
    chroot /mnt useradd -d /home/$username $username
    chroot /mnt usermod -aG $user_groups $username
fi

arch-chroot /mnt mkinitcpio -P

echo "Dont forget to set passwd for root and user!"
