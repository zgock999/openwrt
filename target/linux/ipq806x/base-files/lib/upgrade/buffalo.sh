#!/bin/sh
# Copyright (C) 2018 OpenWrt.org
#

. /lib/functions.sh

# 'firmware1' and 'firmware2' partition on NAND contains
# the kernel and fakerootfs. WXR-2533DHP uses the kernel
# image in 'firmware1'. However, U-Boot checks 'firmware1'
# and 'firmware2' images when booting, and if they are not
# match, do write back image to 'firmware1' from 'firmware2'.
CI_BUF_UBIPART="${CI_BUF_UBIPART:-firmware2}"
KERN_VOLNAME="${KERN_VOLNAME:-kernel}"
FKROOT_VOLNAME="${FKROOT_VOLNAME:-ubi_rootfs}"

buffalo_upgrade_prepare_ubi() {
	local rootfs_length="$1"
	local rootfs_type="$2"

	# search ubi partition
	local mtdnum="$( find_mtd_index "$CI_BUF_UBIPART" )"
	if [ ! "$mtdnum" ]; then
		echo "cannot find ubi mtd partition $CI_BUF_UBIPART"
		return 1
	fi

	# search ubi device (e.g. ubi0) from $CI_BUF_UBIPART
	local ubidev="$( nand_find_ubi "$CI_BUF_UBIPART" )"
	if [ ! "$ubidev" ]; then
		ubiattach -m "$mtdnum"
		sync
		ubidev="$( nand_find_ubi "$CI_BUF_UBIPART" )"
	fi

	# ubi device still not found
	if [ ! "$ubidev" ]; then
		ubiformat /dev/mtd$mtdnum -y
		ubiattach -m "$mtdnum"
		sync
		ubidev="$( nand_find_ubi "$CI_BUF_UBIPART" )"
	fi

	# get root/data ubi volume
	local kern_ubivol="$( nand_find_volume $ubidev $KERN_VOLNAME )"
	local fkroot_ubivol="$( nand_find_volume $ubidev $FKROOT_VOLNAME )"
	local root_ubivol="$( nand_find_volume $ubidev rootfs )"
	local data_ubivol="$( nand_find_volume $ubidev rootfs_data )"

	# remove ubiblock device of rootfs
	local root_ubiblk="ubiblock${root_ubivol:3}"
	if [ "$root_ubivol" -a -e "/dev/$root_ubiblk" ]; then
		echo "removing $root_ubiblk"
		if ! ubiblock -r /dev/$root_ubivol; then
			echo "cannot remove $root_ubiblk"
			return 1;
		fi
	fi

	# backup fakerootfs data
	if [ -n "$fkroot_ubivol" ]; then
		echo "backup fakeroot image from $fkroot_ubivol"
		cat /dev/$fkroot_ubivol > /tmp/fkroot.bin
		local fkroot_length=`(wc -c /tmp/fkroot.bin | awk '{print $1}')`
	fi

	# kill volumes
	[ "$kern_ubivol" ] && ubirmvol /dev/$ubidev -N $KERN_VOLNAME || true
	[ "$fkroot_ubivol" ] && ubirmvol /dev/$ubidev -N $FKROOT_VOLNAME || true
	[ "$root_ubivol" ] && ubirmvol /dev/$ubidev -N rootfs || true
	[ "$data_ubivol" ] && ubirmvol /dev/$ubidev -N rootfs_data || true

	# re-create fakerootfs volume and write backup image
	if ! ubimkvol /dev/$ubidev -N $FKROOT_VOLNAME -s $fkroot_length; then
		echo "cannot create fakeroot volume"
		return 1;
	else
		echo "write fakeroot image to $fkroot_ubivol"
		ubiupdatevol /dev/$fkroot_ubivol -s $fkroot_length /tmp/fkroot.bin
	fi

	# re-create kernel volume
	if ! ubimkvol /dev/$ubidev -N $KERN_VOLNAME -s $kernel_length; then
		echo "cannot create kernel volume"
		return 1;
	fi

	# re-create rootfs volume
	local root_size_param
	if [ "$rootfs_type" = "ubifs" ]; then
		root_size_param="-m"
	else
		root_size_param="-s $rootfs_length"
	fi
	if ! ubimkvol /dev/$ubidev -N rootfs $root_size_param; then
		echo "cannot create rootfs volume"
		return 1;
	fi

	# create rootfs_data for non-ubifs rootfs
	if [ "$rootfs_type" != "ubifs" ]; then
		if ! ubimkvol /dev/$ubidev -N rootfs_data -m; then
			echo "cannot initialize rootfs_data volume"
			return 1
		fi
	fi
	sync
	return 0
}

buffalo_restore_config() {
	sync
	local ubidev=$( nand_find_ubi $CI_BUF_UBIPART )
	local ubivol="$( nand_find_volume $ubidev rootfs_data )"
	[ ! "$ubivol" ] &&
		ubivol="$( nand_find_volume $ubidev rootfs )"
	mkdir /tmp/new_root
	if ! mount -t ubifs /dev/$ubivol /tmp/new_root; then
		echo "mounting ubifs $ubivol failed"
		rmdir /tmp/new_root
		return 1
	fi
	mv "$1" "/tmp/new_root/sysupgrade.tgz"
	umount /tmp/new_root
	sync
	rmdir /tmp/new_root
}

buffalo_do_upgrade_success() {
	local conf_tar="/tmp/sysupgrade.tgz"

	sync
	[ -f "$conf_tar" ] && buffalo_restore_config "$conf_tar"
	echo "sysupgrade successful"
	umount -a
	reboot -f
}

# Extract tar image and write to UBI volume
buffalo_upgrade_tar() {
	local tar_file="$1"
	local kernel_mtd="$(find_mtd_index $CI_BUF_UBIPART)"

	local board_dir=$(tar tf $tar_file | grep -m 1 '^sysupgrade-.*/$')
	board_dir=${board_dir%/}

	local kernel_length=`(tar xf $tar_file ${board_dir}/kernel -O | wc -c) 2> /dev/null`
	local rootfs_length=`(tar xf $tar_file ${board_dir}/root -O | wc -c) 2> /dev/null`

	local rootfs_type="$(identify_tar "$tar_file" ${board_dir}/root)"

	buffalo_upgrade_prepare_ubi "$rootfs_length" "$rootfs_type"

	local ubidev="$( nand_find_ubi "$CI_BUF_UBIPART" )"
	local kern_ubivol="$(nand_find_volume $ubidev $KERN_VOLNAME)"
	tar xf $tar_file ${board_dir}/kernel -O | \
		ubiupdatevol /dev/$kern_ubivol -s $kernel_length -

	local root_ubivol="$(nand_find_volume $ubidev rootfs)"
	tar xf $tar_file ${board_dir}/root -O | \
		ubiupdatevol /dev/$root_ubivol -s $rootfs_length -

	buffalo_do_upgrade_success
}

# Recognize type of passed file and start the upgrade process
platform_do_upgrade_buffalo() {

	local file_type=$(identify $1)

	[ ! "$(find_mtd_index "$CI_BUF_UBIPART")" ] && CI_BUF_UBIPART="rootfs"

	case "$file_type" in
		"ubi" |\
		"ubifs")
			echo "not compatible sysupgrade file."
			return 1
			;;
		*)		buffalo_upgrade_tar $1;;
	esac
}
