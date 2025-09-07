#!/bin/bash
# Script FINAL: Arch Linux + Btrfs completo com snapshots automáticos e systemd-boot
# ATENÇÃO: Apaga todo o disco /dev/sda

set -e

DISK="/dev/sda"
HOSTNAME="arch-btrfs"
TIMEZONE="America/Sao_Paulo"
LOCALE="pt_BR.UTF-8"
USERNAME="user"
SWAPSIZE="4G" # tamanho do swap

echo "==== 1. Preparando o disco ===="
parted $DISK mklabel gpt

# /boot EFI FAT32 512MB
parted -a optimal $DISK mkpart ESP fat32 1MiB 513MiB
parted $DISK set 1 boot on
mkfs.fat -F32 ${DISK}1

# Btrfs restante
parted -a optimal $DISK mkpart primary 513MiB 100%
mkfs.btrfs ${DISK}2

echo "==== 2. Criando subvolumes ===="
mount ${DISK}2 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@swap
umount /mnt

echo "==== 3. Montando subvolumes ===="
mount -o subvol=@,compress=zstd,ssd,space_cache=v2 ${DISK}2 /mnt
mkdir -p /mnt/{boot,home,.snapshots,var,log,tmp,cache,swap}

mount -o subvol=@home,compress=zstd,ssd,space_cache=v2 ${DISK}2 /mnt/home
mount -o subvol=@snapshots,compress=zstd ${DISK}2 /mnt/.snapshots
mount -o subvol=@var,compress=zstd ${DISK}2 /mnt/var
mount -o subvol=@log,compress=zstd ${DISK}2 /mnt/log
mount -o subvol=@tmp,compress=zstd ${DISK}2 /mnt/tmp
mount -o subvol=@cache,compress=zstd ${DISK}2 /mnt/cache

mount ${DISK}1 /mnt/boot

echo "==== 4. Criando swap Btrfs ===="
# Swapfile dentro do subvolume @swap
mount -o subvol=@swap,ssd,space_cache=v2 ${DISK}2 /mnt/swap
truncate -s $SWAPSIZE /mnt/swap/swapfile
chattr +C /mnt/swap/swapfile
chmod 600 /mnt/swap/swapfile
mkswap /mnt/swap/swapfile
swapon /mnt/swap/swapfile

echo "==== 5. Instalando base ===="
pacstrap /mnt base linux linux-firmware vim btrfs-progs sudo systemd

echo "==== 6. Configuração do sistema ===="
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
sed -i 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# Configurar systemd-boot
bootctl --path=/boot install

cat <<LOADER > /boot/loader/loader.conf
default arch
timeout 3
editor 0
LOADER

PARTUUID=$(blkid -s PARTUUID -o value ${DISK}2)
cat <<ENTRY > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=$PARTUUID rootflags=subvol=@,compress=zstd rw
ENTRY

# Habilitar swap
echo "/swap/swapfile none swap sw 0 0" >> /etc/fstab
EOF

echo "==== 7. Criando snapshots iniciais ===="
arch-chroot /mnt /bin/bash <<EOF
btrfs subvolume snapshot / /mnt/.snapshots/root_initial
btrfs subvolume snapshot /home /mnt/.snapshots/home_initial
EOF

echo "==== 8. Configurando snapshots automáticos via systemd-timers ===="
arch-chroot /mnt /bin/bash <<'EOF'
mkdir -p /etc/systemd/system/btrfs-snapshot.timer.d
cat <<TIMER > /etc/systemd/system/btrfs-snapshot.service
[Unit]
Description=Automatic Btrfs snapshot
[Service]
Type=oneshot
ExecStart=/usr/local/bin/btrfs-auto-snapshot.sh
TIMER

cat <<SCRIPT > /usr/local/bin/btrfs-auto-snapshot.sh
#!/bin/bash
DATE=\$(date +%Y-%m-%d_%H-%M-%S)
btrfs subvolume snapshot / /.snapshots/root_\$DATE
btrfs subvolume snapshot /home /.snapshots/home_\$DATE
SCRIPT

chmod +x /usr/local/bin/btrfs-auto-snapshot.sh

cat <<TIMERCONF > /etc/systemd/system/btrfs-snapshot.timer
[Unit]
Description=Run Btrfs snapshots daily
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
TIMERCONF

systemctl enable btrfs-snapshot.timer
EOF

echo "==== INSTALAÇÃO COMPLETA ===="
echo "Reinicie o sistema e remova o Live USB."
