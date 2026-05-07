#!/usr/bin/env bash
#
# install-proxmox-luks.sh
#
# Instala Proxmox VE 9 (sobre Debian 13 Trixie) con:
#   - 2x discos en mirror via mdadm
#   - /boot en RAID1 ext4 (sin cifrar)
#   - root en RAID1 + LUKS2 (Argon2id) + ext4
#   - BIOS legacy boot (sin EFI)
#   - Una sola passphrase para LUKS, prompt en consola en cada boot
#   - 4ta particion en cada disco SIN TOCAR para configurar ZFS POST-install
#     (usando el ZFS que Proxmox trae en su kernel)
#
# Ejecutar como root desde un Debian Live (o rescue mode similar)
# con internet y los discos NO montados.
#
# IMPORTANTE: Editá la sección CONFIGURACIÓN antes de correr.
#

set -euo pipefail

# ============================================================
# CONFIGURACIÓN — EDITAR ANTES DE EJECUTAR
# ============================================================
DISK1=/dev/sda                  # primer disco (se borra completo)
DISK2=/dev/sdb                  # segundo disco (se borra completo)

ROOT_SIZE=100G                  # tamaño de la partición de root (sda3/sdb3)
                                # 100G alcanza de sobra para Debian+Proxmox+ISOs

HOSTNAME=proxmox
FQDN=proxmox.example.com
IP=192.0.2.10
GW=192.0.2.1
NETMASK=255.255.255.0
CIDR=24                         # /24 = 255.255.255.0
IFACE=eno1                      # interfaz de red (ip -o link)

TIMEZONE=America/Argentina/Buenos_Aires

# Hash del password de root: generar con `mkpasswd -m sha-512`
ROOT_PASS_HASH='$6$REEMPLAZAR$ESTO_CON_HASH_REAL'

# Tu clave pública SSH (para root@22 después del boot)
SSH_PUBKEY='ssh-ed25519 AAAA... usuario@laptop'

DEBIAN_RELEASE=trixie
DEBIAN_MIRROR=http://deb.debian.org/debian
# ============================================================

LUKS_KEYFILE=/tmp/luks.key
LOG=/root/install.log
: > "$LOG"

c_green="\033[1;32m"; c_red="\033[1;31m"; c_off="\033[0m"
log() { echo -e "\n${c_green}[$(date +%H:%M:%S)] $*${c_off}" | tee -a "$LOG"; }
err() { echo -e "\n${c_red}[ERROR] $*${c_off}" | tee -a "$LOG" >&2; exit 1; }

# Construye nombre de partición correctamente para SATA o NVMe
part() {
    local d=$1 n=$2
    case "$d" in
        *nvme*|*mmcblk*) echo "${d}p${n}" ;;
        *)               echo "${d}${n}"  ;;
    esac
}

trap 'rc=$?; [[ $rc -ne 0 ]] && echo -e "\n${c_red}Script falló (rc=$rc). Revisá $LOG${c_off}" >&2' EXIT

# ============================================================
# 1. PRE-FLIGHT
# ============================================================
log "Verificaciones previas"
[[ $EUID -eq 0 ]]   || err "Tenés que ser root"
[[ -b "$DISK1" ]]   || err "$DISK1 no existe"
[[ -b "$DISK2" ]]   || err "$DISK2 no existe"
[[ "$DISK1" != "$DISK2" ]] || err "DISK1 y DISK2 son iguales"

# Validar que las variables sensibles fueron editadas
[[ "$ROOT_PASS_HASH" != *"REEMPLAZAR"* ]] || err "Editá ROOT_PASS_HASH (mkpasswd -m sha-512)"
[[ "$SSH_PUBKEY"     != *"AAAA... usuario@laptop"* ]] || err "Editá SSH_PUBKEY con tu clave real"

# Validar que los discos no estén en uso
swapoff -a 2>/dev/null || true
for D in "$DISK1" "$DISK2"; do
    if grep -q "^${D}" /proc/mounts; then
        err "$D tiene particiones montadas. Desmontá antes de continuar."
    fi
done

# ============================================================
# 2. PREPARAR LIVE SYSTEM
# ============================================================
log "Instalando herramientas en el live system"

export DEBIAN_FRONTEND=noninteractive
apt update >>"$LOG" 2>&1
apt install -y \
    debootstrap gdisk parted dosfstools rsync whois \
    cryptsetup mdadm e2fsprogs >>"$LOG" 2>&1 || \
    err "Falló instalación de herramientas en el live."

# ============================================================
# 3. CONFIRMACIÓN DEL USUARIO
# ============================================================
log "Discos seleccionados:"
lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN "$DISK1" "$DISK2" | tee -a "$LOG"
echo
echo -e "${c_red}ATENCIÓN: voy a borrar TODO en $DISK1 y $DISK2${c_off}"
echo -e "Layout: BIOS_boot(1M) + boot_md(2G) + root_md($ROOT_SIZE) + libre(resto)"
read -rp "Escribí YES (en mayúsculas) para continuar: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || err "Cancelado por el usuario"

# ============================================================
# 4. PASSPHRASE LUKS
# ============================================================
log "Configurando passphrase LUKS"
while true; do
    read -rsp "Passphrase LUKS (mínimo 12 caracteres, no se muestra): " P1; echo
    read -rsp "Repetir passphrase: " P2; echo
    [[ "$P1" == "$P2" ]] && [[ ${#P1} -ge 12 ]] && break
    echo "No coinciden o es muy corta (mín 12). Reintentar."
done
echo -n "$P1" > "$LUKS_KEYFILE"
chmod 600 "$LUKS_KEYFILE"
unset P1 P2

# ============================================================
# 5. PARTICIONADO (GPT + BIOS boot)
# ============================================================
log "Particionando $DISK1 y $DISK2"
for D in "$DISK1" "$DISK2"; do
    wipefs -af "$D"
    sgdisk --zap-all "$D"
    sgdisk -n1:1M:+1M           -t1:EF02 -c1:biosboot "$D"   # 1 MiB BIOS boot
    sgdisk -n2:0:+2G            -t2:FD00 -c2:bootraid "$D"   # 2 GiB md /boot
    sgdisk -n3:0:+${ROOT_SIZE}  -t3:FD00 -c3:rootraid "$D"   # root md
    sgdisk -n4:0:0              -t4:8300 -c4:zfsfree  "$D"   # resto: ZFS futuro
done
partprobe "$DISK1" "$DISK2"
udevadm settle
sleep 2

P1_BOOT=$(part "$DISK1" 2);   P2_BOOT=$(part "$DISK2" 2)
P1_ROOT=$(part "$DISK1" 3);   P2_ROOT=$(part "$DISK2" 3)

# ============================================================
# 6. mdadm RAID1 ARRAYS
# ============================================================
log "Creando RAID1 para /boot (md0)"
mdadm --create /dev/md0 --level=1 --raid-devices=2 \
      --metadata=1.2 --homehost="$HOSTNAME" --name=boot \
      --assume-clean --run \
      "$P1_BOOT" "$P2_BOOT"

log "Creando RAID1 para root (md1)"
mdadm --create /dev/md1 --level=1 --raid-devices=2 \
      --metadata=1.2 --homehost="$HOSTNAME" --name=root \
      --assume-clean --run \
      "$P1_ROOT" "$P2_ROOT"

# ============================================================
# 7. /boot ext4 (sin cifrar)
# ============================================================
log "Formateando /boot (ext4 en md0)"
mkfs.ext4 -F -L boot /dev/md0

# ============================================================
# 8. LUKS sobre md1
# ============================================================
log "Cifrando md1 con LUKS2 + Argon2id"
cryptsetup luksFormat \
    --type luks2 --batch-mode \
    --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
    --pbkdf argon2id --iter-time 5000 \
    --label cryptroot \
    /dev/md1 "$LUKS_KEYFILE"

log "Abriendo LUKS como cryptroot"
cryptsetup luksOpen --key-file "$LUKS_KEYFILE" /dev/md1 cryptroot

# ============================================================
# 9. ext4 sobre el LUKS desbloqueado
# ============================================================
log "Formateando root (ext4 en /dev/mapper/cryptroot)"
mkfs.ext4 -F -L root /dev/mapper/cryptroot

# ============================================================
# 10. MOUNT
# ============================================================
log "Montando filesystems en /mnt"
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount /dev/md0 /mnt/boot

# ============================================================
# 11. DEBOOTSTRAP
# ============================================================
log "Ejecutando debootstrap (3-5 min)"
debootstrap --arch=amd64 "$DEBIAN_RELEASE" /mnt "$DEBIAN_MIRROR" >>"$LOG" 2>&1

# ============================================================
# 12. BIND MOUNTS PARA CHROOT
# ============================================================
log "Bind mounts para chroot"
for d in dev dev/pts proc sys run; do
    mkdir -p "/mnt/$d"
    mount --rbind "/$d" "/mnt/$d"
    mount --make-rslave "/mnt/$d"
done

# ============================================================
# 13. UUIDS Y CONFIG PARA CHROOT
# ============================================================
UUID_BOOT=$(blkid -s UUID -o value /dev/md0)
UUID_LUKS=$(blkid -s UUID -o value /dev/md1)            # UUID del contenedor LUKS

cat > /mnt/root/config.sh <<EOF
HOSTNAME='$HOSTNAME'
FQDN='$FQDN'
IP='$IP'
GW='$GW'
NETMASK='$NETMASK'
CIDR='$CIDR'
IFACE='$IFACE'
TIMEZONE='$TIMEZONE'
ROOT_PASS_HASH='$ROOT_PASS_HASH'
SSH_PUBKEY='$SSH_PUBKEY'
DEBIAN_RELEASE='$DEBIAN_RELEASE'
DEBIAN_MIRROR='$DEBIAN_MIRROR'
DISK1='$DISK1'
DISK2='$DISK2'
UUID_BOOT='$UUID_BOOT'
UUID_LUKS='$UUID_LUKS'
EOF
chmod 600 /mnt/root/config.sh

cat > /mnt/root/inside-chroot.sh <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail
source /root/config.sh
export DEBIAN_FRONTEND=noninteractive

c_cyan="\033[1;36m"; c_off="\033[0m"
log() { echo -e "\n${c_cyan}[chroot $(date +%H:%M:%S)] $*${c_off}"; }

# Hostname efectivo en este shell (proxmox-ve installer lo necesita)
hostname "$HOSTNAME"

log "Hostname y /etc/hosts"
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1 localhost
$IP $FQDN $HOSTNAME
EOF

log "Timezone"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime

log "APT sources (main + contrib + non-free-firmware)"
cat > /etc/apt/sources.list <<EOF
deb $DEBIAN_MIRROR $DEBIAN_RELEASE main contrib non-free-firmware
deb $DEBIAN_MIRROR $DEBIAN_RELEASE-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security $DEBIAN_RELEASE-security main contrib non-free-firmware
EOF

apt update
apt install -y locales tzdata
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/default/locale

log "Instalando kernel + LUKS + mdadm + GRUB + SSH"
apt install -y \
    linux-image-amd64 \
    cryptsetup cryptsetup-initramfs \
    mdadm \
    grub-pc \
    openssh-server \
    sudo vim curl rsync ifupdown2 chrony

log "/etc/crypttab (UN solo entry, una sola passphrase al boot)"
cat > /etc/crypttab <<EOF
cryptroot UUID=$UUID_LUKS none luks,discard
EOF

log "/etc/fstab"
cat > /etc/fstab <<EOF
/dev/mapper/cryptroot  /       ext4  defaults,noatime,discard    0 1
UUID=$UUID_BOOT        /boot   ext4  defaults,noatime            0 2
EOF

log "mdadm.conf con UUIDs de los arrays"
mdadm --detail --scan >> /etc/mdadm/mdadm.conf

log "Red estática"
cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto $IFACE
iface $IFACE inet static
    address $IP/$CIDR
    gateway $GW
EOF

cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

log "Root password + SSH key"
echo "root:$ROOT_PASS_HASH" | chpasswd -e
mkdir -p /root/.ssh
echo "$SSH_PUBKEY" > /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

log "SSH del sistema (puerto 22, solo claves)"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl enable ssh

log "GRUB en BIOS legacy (en AMBOS discos)"
cat >> /etc/default/grub <<EOF
GRUB_TERMINAL=console
EOF
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/' /etc/default/grub

update-initramfs -u -k all
grub-install --target=i386-pc --recheck "$DISK1"
grub-install --target=i386-pc --recheck "$DISK2"
update-grub

log "Repos de Proxmox VE"
wget -qO /usr/share/keyrings/proxmox-archive-keyring.gpg \
    "https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"
echo "deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring.gpg] http://download.proxmox.com/debian/pve $DEBIAN_RELEASE pve-no-subscription" \
    > /etc/apt/sources.list.d/pve.list

apt update
apt install -y proxmox-default-kernel
apt install -y proxmox-ve postfix open-iscsi

log "Quitando kernel de Debian (nos quedamos solo con el de PVE)"
apt remove --purge -y linux-image-amd64 'linux-image-6.*-amd64' || true
apt autoremove --purge -y

log "Regenerando initramfs y GRUB con kernel de PVE"
update-initramfs -u -k all
grub-install --target=i386-pc --recheck "$DISK1"
grub-install --target=i386-pc --recheck "$DISK2"
update-grub

log "Configuración de chroot terminada"
CHROOT_EOF

chmod +x /mnt/root/inside-chroot.sh

# ============================================================
# 14. EJECUTAR EL CHROOT
# ============================================================
log "Entrando al chroot (esto tarda ~10-15 min)"
chroot /mnt /root/inside-chroot.sh 2>&1 | tee -a "$LOG"

# ============================================================
# 15. BACKUP DEL HEADER LUKS
# ============================================================
log "Backup del header LUKS en /mnt/root/"
cryptsetup luksHeaderBackup /dev/md1 --header-backup-file /mnt/root/luks-header.bin
chmod 600 /mnt/root/luks-header.bin

# ============================================================
# 16. CLEANUP
# ============================================================
log "Limpieza final"
shred -u /mnt/root/config.sh 2>/dev/null || rm -f /mnt/root/config.sh
shred -u "$LUKS_KEYFILE"

sync

log "Desmontando filesystems"
for d in run sys proc dev/pts dev; do
    umount -lR "/mnt/$d" 2>/dev/null || true
done
umount -l /mnt/boot 2>/dev/null || true
umount -l /mnt 2>/dev/null || true

log "Cerrando LUKS y deteniendo arrays mdadm"
cryptsetup luksClose cryptroot 2>/dev/null || true
mdadm --stop /dev/md0 2>/dev/null || true
mdadm --stop /dev/md1 2>/dev/null || true

trap - EXIT

P1_FREE=$(part "$DISK1" 4)
P2_FREE=$(part "$DISK2" 4)

cat <<EOF

╔══════════════════════════════════════════════════════════════╗
║                    INSTALACIÓN TERMINADA                     ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  PRÓXIMOS PASOS:                                             ║
║                                                              ║
║  1. Desmontá la ISO virtual desde iDRAC                      ║
║     (Virtual Media -> Disconnect)                            ║
║                                                              ║
║  2. systemctl reboot                                         ║
║                                                              ║
║  3. Abrí Virtual Console en iDRAC para ver el arranque       ║
║                                                              ║
║  4. Cuando el sistema pida la passphrase de LUKS:            ║
║     ingresala UNA sola vez en la consola virtual.            ║
║                                                              ║
║  5. Esperar boot completo, luego SSH normal:                 ║
║                                                              ║
║       ssh root@$IP
║                                                              ║
║  6. GUI de Proxmox: https://$IP:8006
║                                                              ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  CRITICAL: Header LUKS guardado en /root/luks-header.bin     ║
║  COPIALO A UN LUGAR SEGURO FUERA DEL SERVER cuanto antes:    ║
║                                                              ║
║       scp root@$IP:/root/luks-header.bin ~/backups/
║                                                              ║
║  Sin ese header + tu passphrase, los datos son               ║
║  irrecuperables si se corrompe el header en el disco.        ║
║                                                              ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  ZFS: $P1_FREE y $P2_FREE quedaron LIBRES.       
║  Configuralos POST-instalación con LUKS + ZFS mirror,        ║
║  usando el ZFS que ya viene con el kernel de Proxmox.        ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝

Log completo: $LOG
EOF
