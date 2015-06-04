#!/bin/bash -e

check_root()
{
    if [ "$(id --user --name)" != 'root' ]
    then
        echo "You are not root. Please run this script as root or with sudo." >&2
        exit 1
    fi
}

check_prog()
{
    local prog=$1
    local pkg=$2

    if [ ! -e "$prog" ]
    then
        MISSING_PKGS="$MISSING_PKGS $pkg"
    fi
}

install_missing_progs()
{
    if [ -n "$MISSING_PKGS" ]
    then
        apt-get update
        apt-get install -y $MISSING_PKGS
    fi

    unset MISSING_PKGS
}

load_config()
{
    config=$1
    local cfg=config/${config}.conf

    if [ -f "$cfg" ]
    then
        source config/weic.conf
    else
        echo "Can't open config file $cfg" >&2
        exit 1
    fi
}

make_workspace()
{
    mkdir -p ignore
    cd ignore

    tmpdir=$(mktemp --directory --tmpdir=. build-XXXXX)
    cd $tmpdir
}

bootstrap_rootfs()
{
    local mirror=http://127.0.0.1:3142/$MIRROR
    local pkgs=$(echo $PKGS | tr ' ' ',')

    debootstrap --arch armhf --include $pkgs --foreign $SUITE rootfs $mirror
    cp /usr/bin/qemu-arm-static rootfs/usr/bin/
    chroot rootfs /debootstrap/debootstrap --second-stage
}

config_locale()
{
    sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' rootfs/etc/locale.gen
    chroot rootfs locale-gen
}

config_apt()
{
    cat <<SOURCES > rootfs/etc/apt/sources.list.d/raspbian.list
deb     http://mirrordirector.raspbian.org/raspbian/                        wheezy main contrib non-free rpi
deb-src http://mirror.ox.ac.uk/sites/archive.raspbian.org/archive/raspbian/ wheezy main contrib non-free rpi
SOURCES

    cat <<SOURCES > rootfs/etc/apt/sources.list.d/collabora.list
deb http://raspberrypi.collabora.com wheezy rpi
SOURCES

    cat <<SOURCES > rootfs/etc/apt/sources.list.d/raspi.list
deb     http://archive.raspberrypi.org/debian/ wheezy main
deb-src http://archive.raspberrypi.org/debian/ wheezy main
SOURCES

    # TODO put to external file?
    cat <<SOURCES > rootfs/etc/apt/sources.list.d/nchc.list
deb     http://opensource.nchc.org.tw/debian/ wheezy           main contrib non-free
deb-src http://opensource.nchc.org.tw/debian/ wheezy           main contrib non-free
deb     http://opensource.nchc.org.tw/debian/ wheezy-backports main contrib non-free
deb-src http://opensource.nchc.org.tw/debian/ wheezy-backports main contrib non-free
deb     http://opensource.nchc.org.tw/debian/ wheezy-updates   main contrib non-free
deb-src http://opensource.nchc.org.tw/debian/ wheezy-updates   main contrib non-free
SOURCES

    chroot rootfs apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 9165938D90FDDD2E
    chroot rootfs apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 82B129927FA3303E
    chroot rootfs apt-key adv --keyserver keyserver.ubuntu.com --recv-keys ED4BF9140C50B1C5

    chroot rootfs apt-get update
    chroot rootfs apt-get install -y $RPIPKGS
    chroot rootfs apt-get install -y $POSTPKGS
    chroot rootfs apt-get clean
}

config_console()
{
    sed -i -e 's!/sbin/getty 38400 tty1!/bin/login -f root tty1 </dev/tty1 >/dev/tty1 2>&1 # RPICFG_TO_DISABLE!' rootfs/etc/inittab
    echo 'T0:23:respawn:/sbin/getty -L ttyAMA0 115200 vt100' >> rootfs/etc/inittab
}

config_fstab()
{
    cat <<FSTAB > rootfs/etc/fstab
proc            /proc           proc    defaults          0       0
/dev/mmcblk0p1  /boot           vfat    defaults          0       2
/dev/mmcblk0p2  /               ext4    defaults,noatime  0       1
FSTAB
}

config_hostname()
{
    echo $HOSTNAME > rootfs/etc/hostname
    echo "127.0.1.1       $HOSTNAME" >> rootfs/etc/hosts
}

config_timezone()
{
    if [ ! -f "rootfs/usr/share/zoneinfo/$TIMEZONE" ]
    then
        echo "Invalid TIMEZONE $TIMEZONE" >&2
        exit 1
    fi

    cp rootfs/usr/share/zoneinfo/$TIMEZONE rootfs/etc/localtime

    cat <<SHELL > rootfs/etc/cron.daily/ntpdate
#/bin/bash -e
ntpdate $NTPSERVER
SHELL
    chmod +x rootfs/etc/cron.daily/ntpdate
}

config_user()
{
    chroot rootfs useradd -s /bin/bash -m $USER
    chroot rootfs gpasswd -a $USER sudo
    sed -i -e "s/$USER:\!:/$USER::/" rootfs/etc/shadow
}

create_image()
{
    img=$(date +'%F')-${config}.img
    dd if=/dev/zero of=$img bs=$IMGSIZE count=0 seek=1

    local size=$(stat --printf=%s $img)
    local sect=$(($size / 512 - 206848))
    sfdisk -S 63 -H 255 -u S -f $img <<PARTITION
2048,204800,0xC,*
206848,$sect,L
PARTITION

    local size=$(($sect * 512))
    losetup -o 1048576   --sizelimit 104857600 /dev/loop0 $img
    losetup -o 105906176 --sizelimit $size     /dev/loop1 $img
    mkfs.vfat    /dev/loop0
    mkfs.ext4 -F /dev/loop1

    mkdir -p dos
    mkdir -p linux
    mount /dev/loop0 dos
    mount /dev/loop1 linux

    echo '(log) Installing DOS partition ...'
    cp -pr rootfs/boot/* dos/
    echo '(log) Installing Linux partition ...'
    cp -pr rootfs/*      linux/
    rm -rf linux/boot/*

    umount dos
    umount linux
    losetup -d /dev/loop0
    losetup -d /dev/loop1

    echo '(log) Compress image ...'
    gzip $img
    img=${img}.gz

    unset config
}

do_housekeeping()
{
    cd ..
    cd ..

    mv ignore/$tmpdir/$img images/

    echo "Image is ready at images/$img"
    echo
    echo "User: $USER"
    echo "Password: <empty>"

    unset img
    unset tmpdir
}

check_root

check_prog /usr/sbin/debootstrap    debootstrap
check_prog /usr/sbin/apt-cacher     apt-cacher
check_prog /usr/bin/qemu-arm-static qemu-user-static
check_prog /sbin/mkfs.vfat          dosfstools
install_missing_progs

load_config $@

make_workspace
bootstrap_rootfs
config_locale
config_apt
config_console
config_fstab
config_hostname
config_timezone
config_user

create_image
do_housekeeping
