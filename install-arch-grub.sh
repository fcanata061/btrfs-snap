#!/bin/bash
# Script de instalação Arch Linux com Btrfs e snapshots
# ATENÇÃO: Apaga todo o disco /dev/sda

set -e

DISK="/dev/sda"
HOSTNAME="arch-btrfs"
TIMEZONE="America/Sao_Paulo"
LOCALE="pt_BR.UTF-8"
USERNAME="user"

echo "==== 1. Preparando o disco ===="
# Criar GPT
parted $DISK mklabel gpt

# Criar partições
parted -a optimal $DISK mkpart primary 1MiB 513MiB
mkfs.ext4 ${DISK}1

parted -a optimal $DISK mkpart primary 513MiB 100%
mkfs.btrfs ${DISK}2

echo "==== 2. Criando subvolumes ===="
mount ${DISK}2 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var
umount /mnt

echo "==== 3. Montando subvolumes ===="
mount -o subvol=@,compress=zstd,ssd,space_cache=v2 ${DISK}2 /mnt
mkdir -p /mnt/{boot,home,.snapshots,var}
mount -o subvol=@home,compress=zstd,ssd,space_cache=v2 ${DISK}2 /mnt/home
mount -o subvol=@snapshots,compress=zstd ${DISK}2 /mnt/.snapshots
mount -o subvol=@var,compress=zstd ${DISK}2 /mnt/var
mount ${DISK}1 /mnt/boot

echo "==== 4. Instalando base ===="
pacstrap /mnt base linux linux-firmware vim btrfs-progs sudo

echo "==== 5. Configuração do sistema ===="
genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
# Timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Locale
echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname

# Usuário
useradd -m -G wheel $USERNAME
echo "$USERNAME:archlinux" | chpasswd

# Permitir sudo para grupo wheel
sed -i 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# Instalar bootloader GRUB (UEFI)
pacman -S --noconfirm grub efibootmgr
mkdir -p /boot/EFI
mount ${DISK}1 /boot/EFI
grub-install --target=x86_64-efi --efi-directory=/boot/EFI --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
EOF

echo "==== 6. Criação de snapshots iniciais ===="
arch-chroot /mnt /bin/bash <<EOF
btrfs subvolume snapshot / /mnt/.snapshots/root_initial
btrfs subvolume snapshot /home /mnt/.snapshots/home_initial
EOF

echo "==== INSTALAÇÃO COMPLETA ===="
echo "Reinicie o sistema e remova o Live USB."
