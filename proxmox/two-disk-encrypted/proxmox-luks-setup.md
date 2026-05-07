# Proxmox VE 9 con discos cifrados (LUKS + ZFS) — Guía completa

Servidor dedicado en datacenter, 2 discos SSD enterprise, acceso por IPMI.
Setup con cifrado completo de datos via LUKS, passphrase manual al boot,
sin llaves almacenadas en el server.

---

## 1. Arquitectura

### Stack final

```
┌──────────────────────────────────────────────────────────────────┐
│ /boot   →  ext4  →  md0 (mdadm RAID1)  →  sda2 + sdb2  (sin cifrar)
│                                                                  │
│ /       →  ext4  →  cryptroot (LUKS2)  →  md1 (RAID1)  →  sda3 + sdb3
│                                                                  │
│ ZFS     →  rpool (mirror)  →  zfs0 (LUKS2) + zfs1 (LUKS2)        │
│                                ↓               ↓                 │
│                              sda4            sdb4                │
└──────────────────────────────────────────────────────────────────┘
```

### Layout de particiones (cada disco)

| Partición | Tamaño   | Tipo  | Uso                                |
|-----------|----------|-------|------------------------------------|
| sdX1      | 1 MiB    | EF02  | BIOS boot partition (GRUB)         |
| sdX2      | 2 GiB    | FD00  | miembro de md0 (/boot)             |
| sdX3      | 100 GiB  | FD00  | miembro de md1 (root cifrado)      |
| sdX4      | resto    | 8300  | LUKS individual → ZFS mirror       |

### Threat model cubierto

- **Disco robado** (1 o ambos): irrecuperable sin passphrase
- **Server robado apagado**: irrecuperable sin passphrase
- **Reboot no asistido**: requiere intervención manual via IPMI

### NO cubre

- Server comprometido a nivel OS mientras corre (la passphrase está en RAM)
- Cold boot attack (irrelevante en datacenter con seguridad física)
- Evil maid en `/boot` no cifrado (irrelevante sin acceso físico al server prendido)

### Decisiones de diseño

| Decisión                      | Por qué                                              |
|-------------------------------|------------------------------------------------------|
| BIOS legacy en lugar de UEFI  | Más simple, sin ESP que sincronizar entre discos     |
| mdadm para /boot              | Estándar, robusto, GRUB no necesita módulos extra    |
| mdadm + LUKS para root        | Una sola operación de cifrado, un solo prompt        |
| LUKS por disco para ZFS       | ZFS ve devices individuales (autohealing funciona)   |
| `decrypt_keyctl` keyscript    | Una passphrase desbloquea las 3 LUKS                 |
| ZFS post-install              | Usa el ZFS del kernel de Proxmox, sin DKMS           |

---

## 2. Pre-instalación: bootear el live system via IPMI

### Lo que necesitás antes de empezar

- **ISO de Debian Live Standard 13.x** (debian.org/CD/live/, ~1.5 GB)
- **Acceso a IPMI** del server con permisos para Virtual Media
- **Hash del password de root** generado con `mkpasswd -m sha-512` en cualquier Linux
- **Tu clave pública SSH** (`cat ~/.ssh/id_ed25519.pub`)
- **Passphrase fuerte** anotada en password manager (mínimo 20 caracteres)
- **IP, gateway, máscara, hostname, FQDN** del server definidos

### Pasos en IPMI

1. Configuration → Virtual Media → Mapear ISO de Debian Live
2. Configuration → BIOS Settings → Verificar "Boot Mode: BIOS" (no UEFI)
3. Configuration → BIOS Settings → One-Time Boot → Virtual CD/DVD/ISO → Apply
4. Server Power → Power Cycle
5. Abrir Virtual Console (HTML5) y esperar el menú GRUB del live
6. Seleccionar "Live system"

### Habilitar SSH en el live para pasarte a una terminal cómoda

Una vez en la consola virtual del live (login: `user` / `live`):

```bash
sudo -i

# Verificar red
ip a
ping -c 2 8.8.8.8

# Si DHCP no funcionó, IP estática:
# ip addr add 192.0.2.10/24 dev eno1
# ip route add default via 192.0.2.1
# echo "nameserver 1.1.1.1" > /etc/resolv.conf

# SSH temporal con password
passwd root
systemctl start ssh
```

Si `ssh` no está instalado en el live:

```bash
apt update && apt install -y openssh-server
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart ssh
```

Ahora **cerrá la Virtual Console** y conectate desde tu laptop:

```bash
ssh root@<server-ip>
tmux                # IMPORTANTE: usar tmux/screen para no perder progreso
```

---

## 3. Ejecutar el script de instalación

### Subir el script

Tres opciones según tu workflow:

**Opción A — pegar con `cat`**:
```bash
cat > /root/install.sh << 'INSTALLEOF'
# ... pegás todo el contenido de install-proxmox-luks.sh ...
INSTALLEOF
chmod +x /root/install.sh
```

**Opción B — `scp` desde tu laptop**:
```bash
# Desde tu laptop:
scp install-proxmox-luks.sh root@<server-ip>:/root/
```

**Opción C — `curl` desde un repo**:
```bash
curl -fsSL https://github.com/smedb/cookbook/raw/main/proxmox/two-disk-encrypted/install-proxmox-luks.sh -o /root/install.sh
chmod +x /root/install.sh
```

### Identificar los discos correctos

```bash
lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN
```

Anotá los nombres reales (`sda`/`sdb`, `nvme0n1`/`nvme1n1`, etc.) y poné esos en el script. **No incluir `sr0` (la ISO virtual) ni USBs**.

### Editar el script

```bash
vim /root/install.sh
```

Variables a modificar al principio del archivo:

| Variable           | Ejemplo                                              |
|--------------------|------------------------------------------------------|
| `DISK1`, `DISK2`   | `/dev/sda`, `/dev/sdb`                               |
| `ROOT_SIZE`        | `100G` (default ok para la mayoría)                  |
| `HOSTNAME`, `FQDN` | `proxmox`, `proxmox.tudominio.com`                   |
| `IP`, `GW`, `NETMASK`, `CIDR` | tus valores de red                        |
| `IFACE`            | `eno1` (verificar con `ip -o link`)                  |
| `TIMEZONE`         | `America/Argentina/Buenos_Aires`                     |
| `ROOT_PASS_HASH`   | salida de `mkpasswd -m sha-512`                      |
| `SSH_PUBKEY`       | contenido de tu `~/.ssh/id_*.pub`                    |

### Correr el script

```bash
chmod +x /root/install.sh
/root/install.sh 2>&1 | tee /root/install.log
```

El script va a:

1. Validar variables
2. Confirmar discos (esperá YES en mayúsculas)
3. Pedir passphrase LUKS (dos veces, mínimo 12 caracteres)
4. Particionar discos
5. Crear arrays mdadm
6. Cifrar root con LUKS2 + Argon2id
7. Hacer debootstrap de Debian Trixie
8. Configurar el sistema en chroot
9. Instalar Proxmox VE
10. Hacer backup del header LUKS de root

Tarda ~15-20 minutos según ancho de banda y CPU.

### Cleanup pre-reboot

Cuando el script termina:

```bash
# Bajar el log y los headers ANTES de rebootear (el live se pierde):
scp /root/install.log laptop:~/proxmox-install/
scp /mnt/root/luks-header.bin laptop:~/proxmox-install/  # si quedó accesible
```

---

## 4. Primer boot

### Antes del reboot

1. **IPMI → Virtual Media → Disconnect** (clave: si no, vuelve a bootear la ISO)
2. **IPMI → BIOS → Boot Order → Hard Drive primero**
3. **Abrir Virtual Console** (sólo para mirar, no para trabajar)
4. `systemctl reboot` desde tu SSH al live

### Lo que vas a ver

1. POST del BIOS
2. GRUB (carga rápido)
3. Kernel arrancando
4. Mensaje:
   ```
   Please unlock disk cryptroot:
   ```
5. **Tipear la passphrase en la Virtual Console** y ENTER
6. Boot continúa, llega a login de Proxmox

### Conectarse

```bash
# SSH normal (puerto 22)
ssh root@<server-ip>

# GUI de Proxmox
# https://<server-ip>:8006
# Usuario: root, password: el que pusiste en ROOT_PASS_HASH
# Realm: Linux PAM standard authentication
```

### Backup crítico del header LUKS de root

```bash
# Desde tu laptop:
scp root@<server-ip>:/root/luks-header.bin ~/backups/proxmox-luks-root-header.bin
```

**Sin este header + tu passphrase, los datos son irrecuperables si se corrompe el header en el disco.** Guardalo en al menos 2 lugares offline.

### Slot de recuperación (recomendado)

Crear una passphrase de emergencia larga, generada aleatoriamente, guardada solo en password manager:

```bash
# En el server:
openssl rand -base64 64    # copiala al password manager

cryptsetup luksAddKey /dev/md1   # te pide la passphrase actual, después la nueva
```

---

## 5. Post-install: ZFS sobre LUKS

### Setup de las particiones libres

Las particiones `sda4` y `sdb4` quedaron sin tocar. Ahora las preparamos.

**Importante**: usá **exactamente la misma passphrase** que para el root. Sin esto el `decrypt_keyctl` no funciona y vas a tener prompts duplicados al boot.

```bash
# 1. LUKS en sda4
cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
    --pbkdf argon2id --iter-time 5000 \
    --label zfs0 \
    /dev/sda4

# 2. LUKS en sdb4 (misma passphrase!)
cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
    --pbkdf argon2id --iter-time 5000 \
    --label zfs1 \
    /dev/sdb4

# 3. Abrir
cryptsetup luksOpen /dev/sda4 zfs0
cryptsetup luksOpen /dev/sdb4 zfs1

# 4. Backup de los nuevos headers (CRÍTICO)
cryptsetup luksHeaderBackup /dev/sda4 --header-backup-file /root/luks-zfs0-header.bin
cryptsetup luksHeaderBackup /dev/sdb4 --header-backup-file /root/luks-zfs1-header.bin
chmod 600 /root/luks-zfs*-header.bin

# Bajarlos a un lugar seguro
# scp root@server:/root/luks-zfs*-header.bin ~/backups/

# 5. Slot de recuperación en los nuevos LUKS también
cryptsetup luksAddKey /dev/sda4   # usar la misma passphrase de recuperación que en md1
cryptsetup luksAddKey /dev/sdb4
```

### Crear el pool ZFS

```bash
zpool create -o ashift=12 -o autotrim=on \
    -O compression=lz4 -O atime=off -O xattr=sa \
    -O acltype=posixacl -O dnodesize=auto -O normalization=formD \
    rpool mirror /dev/mapper/zfs0 /dev/mapper/zfs1

# Verificar
zpool status rpool

# Limitar ARC (con 128GB RAM, dejá memoria para VMs)
echo "options zfs zfs_arc_max=17179869184" > /etc/modprobe.d/zfs.conf
update-initramfs -u
```

### Configurar `decrypt_keyctl` para una sola passphrase al boot

Editar `/etc/crypttab` para que quede así:

```bash
# Generar las líneas con UUIDs reales:
cat <<EOF
cryptroot UUID=$(blkid -s UUID -o value /dev/md1)  none luks,discard,initramfs,keyscript=decrypt_keyctl
zfs0      UUID=$(blkid -s UUID -o value /dev/sda4) none luks,discard,initramfs,keyscript=decrypt_keyctl
zfs1      UUID=$(blkid -s UUID -o value /dev/sdb4) none luks,discard,initramfs,keyscript=decrypt_keyctl
EOF
```

Pegá la salida en `/etc/crypttab` (reemplaza el archivo entero).

**Verificar que `keyutils` está instalado** (provee el binario `keyctl` que usa el keyscript):

```bash
apt install -y keyutils
```

**Regenerar initramfs**:

```bash
update-initramfs -u -k all
```

**Verificar que el initramfs incluye decrypt_keyctl y keyctl**:

```bash
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'keyctl|decrypt_keyctl'
# Debería mostrar al menos:
#   lib/cryptsetup/scripts/decrypt_keyctl
#   ...sbin/keyctl
```

### Persistencia del pool al boot

```bash
zpool set cachefile=/etc/zfs/zpool.cache rpool

systemctl enable zfs-import-cache.service
systemctl enable zfs-mount.service
systemctl enable zfs.target
```

### Agregar pool a Proxmox como storage

**Por GUI**: Datacenter → Storage → Add → ZFS → ID: `rpool-data`, Pool: `rpool`, Content: Disk image, Container

**Por CLI**:
```bash
pvesm add zfspool rpool-data --pool rpool --content images,rootdir
```

### Test de boot

Antes de poner cargas reales, hacé un reboot de prueba:

```bash
systemctl reboot
```

En la Virtual Console deberías ver **un solo prompt** de passphrase. Si te pide más de una vez, algo está mal con el `decrypt_keyctl` (verificar que las 3 LUKS tienen exactamente la misma passphrase).

Después del boot:
```bash
# Verificar que las 3 LUKS están abiertas
ls /dev/mapper/

# Verificar que el pool está importado
zpool status

# Verificar que las VMs storage está disponible
pvesm status
```

---

### Monitoreo de discos y arrays

```bash
# Estado mdadm
cat /proc/mdstat
mdadm --detail /dev/md0 /dev/md1

# Estado ZFS
zpool status
zpool list

# SMART
smartctl -a /dev/sda
smartctl -a /dev/sdb
```

### Scrubs periódicos

```bash
# ZFS — automatizado por Proxmox por default (mensual)
# Verificar status:
zpool status

# Forzar scrub manual:
zpool scrub rpool

# mdadm — agregar a cron mensual:
echo '0 3 1 * * root /usr/sbin/mdadm --action=check /dev/md0 /dev/md1' \
    > /etc/cron.d/mdadm-scrub
```

---

## 6. Reemplazo de disco roto

### Diagnóstico

Cuando un disco falla, vas a ver:

```bash
# mdadm reporta arrays degradados
cat /proc/mdstat
# md0 : active raid1 sdb2[1] (F)sda2[0]
#       [_U]  ← uno de los miembros falló

# ZFS reporta pool degradado
zpool status rpool
# state: DEGRADED
# config:
#   rpool         DEGRADED
#     mirror-0    DEGRADED
#       zfs0      UNAVAIL
#       zfs1      ONLINE
```

El sistema **sigue funcionando normalmente** mientras los pools/arrays están en modo degraded. Tenés tiempo para reemplazar el disco sin pánico.

### Procedimiento

Asumiendo que falló `sda` y el datacenter ya hizo el cambio físico (el disco nuevo aparece como `/dev/sda` otra vez).

#### Paso 1: Replicar tabla de particiones de sdb a sda

```bash
# Copiar el layout exacto del disco sano al nuevo
sgdisk --replicate=/dev/sda /dev/sdb
sgdisk --randomize-guids /dev/sda    # GUIDs nuevos para evitar conflictos

partprobe /dev/sda
udevadm settle
```

#### Paso 2: Reinstalar GRUB en el disco nuevo

```bash
grub-install --target=i386-pc --recheck /dev/sda
```

Esto es crítico para mantener boot redundante. Si no lo hacés y muere el otro disco después, no booteás más.

#### Paso 3: Reagregar a md0 (boot)

```bash
mdadm --add /dev/md0 /dev/sda2

# Mirar el resync (rápido, 2 GiB):
watch cat /proc/mdstat
```

Tarda segundos.

#### Paso 4: Reagregar a md1 (root cifrado)

```bash
mdadm --add /dev/md1 /dev/sda3

# Resync más largo (100 GiB), seguir con:
watch cat /proc/mdstat
```

Tarda ~10-30 minutos según velocidad de los SSDs. **El sistema sigue funcionando** durante el resync.

#### Paso 5: Reemplazar el LUKS+ZFS en sda4

Esta parte es la única donde necesitás interacción manual con la passphrase:

```bash
# Formatear LUKS en el disco nuevo (te pide la passphrase)
cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 --hash sha512 \
    --pbkdf argon2id --iter-time 5000 \
    --label zfs0 \
    /dev/sda4

# Agregar también la passphrase de recuperación
cryptsetup luksAddKey /dev/sda4

# Abrirlo
cryptsetup luksOpen /dev/sda4 zfs0_new

# Actualizar /etc/crypttab con el nuevo UUID
NEW_UUID=$(blkid -s UUID -o value /dev/sda4)
sed -i "s|^zfs0 .*|zfs0 UUID=$NEW_UUID none luks,discard,initramfs,keyscript=decrypt_keyctl|" /etc/crypttab

# Backup del nuevo header
cryptsetup luksHeaderBackup /dev/sda4 --header-backup-file /root/luks-zfs0-header.bin
chmod 600 /root/luks-zfs0-header.bin
# scp a backup offline

# Regenerar initramfs
update-initramfs -u -k all
```

#### Paso 6: Reemplazar el device en el pool ZFS

```bash
# Decirle a ZFS que reemplace zfs0 (el viejo, marcado como UNAVAIL)
# por zfs0_new (recién abierto)
zpool replace rpool zfs0 /dev/mapper/zfs0_new

# Mirar el resilver:
watch zpool status rpool
```

El resilver puede tardar de 30 minutos a varias horas según cuántos datos hay en el pool. **El sistema sigue funcionando** durante el resilver.

#### Paso 7: Cleanup de los nombres de mapper

Después que el resilver termine, conviene normalizar los nombres para que el próximo reboot los abra como `zfs0` (y no `zfs0_new`):

```bash
# Cerrar el mapper actual
# (esto requiere exportar el pool primero)
zpool export rpool
cryptsetup luksClose zfs0_new

# Reabrir con el nombre correcto
cryptsetup luksOpen /dev/sda4 zfs0
zpool import rpool
```

O alternativamente: dejar `zfs0_new` y rebootear. Después del reboot, el crypttab abrirá como `zfs0` (porque eso dice el archivo) y todo queda normal.

#### Paso 8: Verificar todo

```bash
# Arrays mdadm sanos
cat /proc/mdstat
# md0 : active raid1 sdb2[1] sda2[0]  ← ambos miembros OK
# md1 : active raid1 sdb3[1] sda3[0]

# ZFS sano
zpool status rpool
# state: ONLINE
# scan: resilvered XXX in YYY ago

# GRUB en ambos discos
dd if=/dev/sda bs=512 count=1 2>/dev/null | hexdump -C | head -1
dd if=/dev/sdb bs=512 count=1 2>/dev/null | hexdump -C | head -1
# (no son idénticos, pero los dos deberían mostrar bytes != 00)
```

#### Paso 9: Reboot de prueba (opcional pero recomendado)

```bash
systemctl reboot
```

En la Virtual Console: una sola passphrase, sistema arranca, todo OK.

---

## 7. Recuperación desde backup de header LUKS

Si el header de un LUKS se corrompe (raro pero pasa), no podés desbloquearlo aunque tengas la passphrase. Acá entra el backup que hicimos.

### Síntoma

```bash
cryptsetup luksOpen /dev/sda4 zfs0
# Device /dev/sda4 is not a valid LUKS device.
```

### Restore

**ATENCIÓN**: esto sobrescribe el inicio del device. Si tenés dudas, hacé un backup raw primero:

```bash
dd if=/dev/sda4 of=/safe/place/sda4-first-16M.bin bs=1M count=16
```

Restore del header:

```bash
cryptsetup luksHeaderRestore /dev/sda4 --header-backup-file /backups/luks-zfs0-header.bin
```

Verificar:

```bash
cryptsetup luksDump /dev/sda4
cryptsetup luksOpen /dev/sda4 zfs0   # te pide la passphrase
```

Si funciona, ZFS detecta el device y el pool vuelve a funcionar normalmente.

---

## 8. Troubleshooting

### El boot pide passphrase 2 o 3 veces (en lugar de 1)

Probable: las LUKS no tienen la misma passphrase. Verificá:

```bash
# Test cada slot:
cryptsetup luksOpen --test-passphrase /dev/md1     # ingresar passphrase
cryptsetup luksOpen --test-passphrase /dev/sda4    # misma passphrase
cryptsetup luksOpen --test-passphrase /dev/sdb4    # misma passphrase
```

Si alguna falla con "No key available", agregá la passphrase correcta:

```bash
cryptsetup luksAddKey /dev/sda4   # te pide la actual, después la nueva (igual a las otras)
```

### "decrypt_keyctl: not found" o "keyctl: not found" en el initramfs

Falta el paquete `keyutils`:

```bash
apt install -y keyutils
update-initramfs -u -k all
```

### El sistema no bootea después de cambiar /etc/crypttab

Bootear desde el live system, abrir LUKS manualmente, montar root, chrootear, arreglar crypttab:

```bash
# Desde el live:
mdadm --assemble --scan
cryptsetup luksOpen /dev/md1 cryptroot
mount /dev/mapper/cryptroot /mnt
mount /dev/md0 /mnt/boot
for d in dev dev/pts proc sys run; do mount --rbind /$d /mnt/$d; done
chroot /mnt /bin/bash

# En el chroot, arreglar /etc/crypttab y regenerar initramfs:
vim /etc/crypttab
update-initramfs -u -k all
exit

# Cleanup y reboot:
for d in run sys proc dev/pts dev; do umount -l /mnt/$d; done
umount /mnt/boot /mnt
cryptsetup luksClose cryptroot
mdadm --stop /dev/md0 /dev/md1
reboot
```

### Olvidé la passphrase principal pero tengo la de recuperación

```bash
# Bootear, ingresar la de recuperación en consola
# Una vez logueado, agregar una nueva passphrase principal:
cryptsetup luksAddKey /dev/md1     # te pide la de recuperación, después la nueva
cryptsetup luksAddKey /dev/sda4
cryptsetup luksAddKey /dev/sdb4

# Borrar el slot viejo (cualquier slot que no sea el de recuperación)
cryptsetup luksDump /dev/md1   # ver qué slots hay
cryptsetup luksKillSlot /dev/md1 0   # ejemplo: borra slot 0
```

### El pool ZFS no importa al boot

Verificar que las LUKS se abrieron antes del intento de import:

```bash
journalctl -b -u zfs-import-cache.service
ls /dev/mapper/   # zfs0 y zfs1 tienen que estar
```

Si las mappers no están, el problema es con el crypttab/initramfs. Si están pero el import falla:

```bash
# Forzar import manual
zpool import -f rpool
```

---

## 10. Checklist final de seguridad

- [ ] Passphrase principal de mínimo 20 caracteres, en password manager
- [ ] Passphrase de recuperación generada con `openssl rand`, en password manager
- [ ] Headers LUKS de las 3 particiones backupeados off-server (al menos 2 lugares)
- [ ] Test de reboot exitoso con un solo prompt de passphrase
- [ ] Slot de recuperación verificado con `cryptsetup luksOpen --test-passphrase` en las 3 LUKS
- [ ] `zfs-zed` configurado con email para alertas
- [ ] `mdmonitor` configurado con email para alertas
- [ ] SMART monitoring habilitado (`smartd`)
- [ ] Backup de `/root/install.log` y todos los headers en lugar seguro
- [ ] Documentado dónde está la passphrase y los headers (no solo en tu cabeza)
- [ ] Plan de qué hacer si IPMI se cae y no podés ingresar la passphrase
- [ ] Backups regulares de las VMs (Proxmox Backup Server u otro mecanismo) — el cifrado en reposo no es backup

---

## Referencias

- Proxmox VE on Debian 13 Trixie: https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie
- LUKS2 manual: https://gitlab.com/cryptsetup/cryptsetup/-/wikis/home
- ZFS on Linux: https://openzfs.github.io/openzfs-docs/
- mdadm: https://raid.wiki.kernel.org/
