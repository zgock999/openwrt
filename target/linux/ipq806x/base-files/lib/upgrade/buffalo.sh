#!/bin/sh
# Copyright (C) 2018 OpenWrt.org
#

. /lib/functions.sh

# 'firmware1' and 'firmware2' partition on NAND contains
# the kernel and fakerootfs. WXR-2533DHP uses the kernel
# image in 'firmware1'. However, U-Boot checks 'firmware1'
# and 'firmware2' images when booting, and if they are not
# match, do write back image to 'firmware1' from 'firmware2'.
CI_BUF_KERNPART="firmware2"
KERN_VOLNAME="kernel"
FKROOT_VOLNAME="ubi_rootfs"

# 'ubi' partition on NAND contains UBI
CI_BUF_ROOTPART="${CI_BUF_ROOTPART:-ubi}"

buffalo_upgrade_prepare_kernel() {
	# search kernel ubi partition
	local kern_mtdnum="$( find_mtd_index "$CI_BUF_KERNPART" )"
	if [ ! "$kern_mtdnum" ]; then
		echo "cannot find kernel mtd partition $CI_BUF_KERNPART"
		return 1
	fi

	# search kernel ubi device (e.g. ubi0) from $CI_BUF_KERNPART
	local kern_ubidev="$( nand_find_ubi "$CI_BUF_KERNPART" )"
	if [ ! "$kern_ubidev" ]; then
		ubiattach -m "$kern_mtdnum"
		sync
		kern_ubidev="$( nand_find_ubi "$CI_BUF_KERNPART" )"
	fi

	# kernel ubi device still not found
	if [ ! "$kern_ubidev" ]; then
		echo "cannot find kernel ubi device"
		return 1
	fi

	# get kernel/fkroot/fkdata ubi volume
	local kern_ubivol="$( nand_find_volume $kern_ubidev $KERN_VOLNAME )"
	local fkroot_ubivol="$( nand_find_volume $kern_ubidev $FKROOT_VOLNAME )"
	local fkdata_ubivol="$( nand_find_volume $kern_ubidev rootfs_data )"

	# backup fake rootfs data
	if [ -n "$fkroot_ubivol" ]; then
		echo "backup from fakeroot volume"
		cat /dev/$fkroot_ubivol > /tmp/fkroot.bin
		local fkroot_length=`(wc -c /tmp/fkroot.bin | awk '{print $1}')`
	fi

	# kill volumes
	[ "$kern_ubivol" ] && ubirmvol /dev/$kern_ubidev -N $KERN_VOLNAME || true
	[ "$fkroot_ubivol" ] && ubirmvol /dev/$kern_ubidev -N $FKROOT_VOLNAME || true
	[ "$fkdata_ubivol" ] && ubirmvol /dev/$kern_ubidev -N rootfs_data || true

	# re-create kernel volume
	if ! ubimkvol /dev/$kern_ubidev -N $KERN_VOLNAME -s $kernel_length; then
		echo "cannot create kernel volume"
		return 1;
	fi

	# re-create fake rootfs volume and write backup image
	if ! ubimkvol /dev/$kern_ubidev -N $FKROOT_VOLNAME -s $fkroot_length; then
		echo "cannot create fakeroot volume"
		return 1;
	else
		echo "write backup fakeroot image to volume $fkroot_ubivol"
		ubiupdatevol /dev/$fkroot_ubivol -s $fkroot_length /tmp/fkroot.bin
	fi

	# re-create fake data volume
	if ! ubimkvol /dev/$kern_ubidev -N rootfs_data -m; then
		echo "cannot create fake data volume"
		return 1;
	fi
}

buffalo_upgrade_prepare_root() {
	local rootfs_length="$1"
	local rootfs_type="$2"

	# search rootfs ubi partition
	local rootfs_mtdnum="$( find_mtd_index "$CI_BUF_ROOTPART" )"
	if [ ! "$rootfs_mtdnum" ]; then
		echo "cannot find ubi mtd partition $CI_BUF_ROOTPART"
		return 1
	fi

	# search rootfs ubi device (e.g. ubi0) from $CI_BUF_ROOTPART
	local rootfs_ubidev="$( nand_find_ubi "$CI_BUF_ROOTPART" )"
	if [ ! "$rootfs_ubidev" ]; then
		ubiattach -m "$rootfs_mtdnum"
		sync
		rootfs_ubidev="$( nand_find_ubi "$CI_BUF_ROOTPART" )"
	fi

	# rootfs ubi device still not found
	if [ ! "$rootfs_ubidev" ] && [ "$rootfs_mtdnum" -ne "$kern_mtdnum" ]; then
		ubiformat /dev/mtd$rootfs_mtdnum -y
		ubiattach -m "$rootfs_mtdnum"
		sync
		rootfs_ubidev="$( nand_find_ubi "$CI_BUF_ROOTPART" )"
	fi

	# get root/data ubi volume
	local root_ubivol="$( nand_find_volume $rootfs_ubidev rootfs )"
	local data_ubivol="$( nand_find_volume $rootfs_ubidev rootfs_data )"

	# remove ubiblock device of rootfs
	local root_ubiblk="ubiblock${root_ubivol:3}"
	if [ "$root_ubivol" -a -e "/dev/$root_ubiblk" ]; then
		echo "removing $root_ubiblk"
		if ! ubiblock -r /dev/$root_ubivol; then
			echo "cannot remove $root_ubiblk"
			return 1;
		fi
	fi

	# kill volumes
	[ "$root_ubivol" ] && ubirmvol /dev/$rootfs_ubidev -N rootfs || true
	[ "$data_ubivol" ] && ubirmvol /dev/$rootfs_ubidev -N rootfs_data || true

	# re-create rootfs volume
	local root_size_param
	if [ "$rootfs_type" = "ubifs" ]; then
		root_size_param="-m"
	else
		root_size_param="-s $rootfs_length"
	fi
	if ! ubimkvol /dev/$rootfs_ubidev -N rootfs $root_size_param; then
		echo "cannot create rootfs volume"
		return 1;
	fi

	# create rootfs_data for non-ubifs rootfs
	if [ "$rootfs_type" != "ubifs" ]; then
		if ! ubimkvol /dev/$rootfs_ubidev -N rootfs_data -m; then
			echo "cannot initialize rootfs_data volume"
			return 1
		fi
	fi
	sync
	return 0
}

buffalo_restore_config() {
	sync
	local ubidev=$( nand_find_ubi $CI_BUF_ROOTPART )
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
	local kernel_mtd="$(find_mtd_index $CI_BUF_KERNPART)"

	local board_dir=$(tar tf $tar_file | grep -m 1 '^sysupgrade-.*/$')
	board_dir=${board_dir%/}

	local kernel_length=`(tar xf $tar_file ${board_dir}/kernel -O | wc -c) 2> /dev/null`
	local rootfs_length=`(tar xf $tar_file ${board_dir}/root -O | wc -c) 2> /dev/null`

	local rootfs_type="$(identify_tar "$tar_file" ${board_dir}/root)"

	buffalo_upgrade_prepare_kernel
	buffalo_upgrade_prepare_root "$rootfs_length" "$rootfs_type"

	local kern_ubidev="$( nand_find_ubi "$CI_BUF_KERNPART" )"
	local kern_ubivol="$(nand_find_volume $kern_ubidev $KERN_VOLNAME)"
	tar xf $tar_file ${board_dir}/kernel -O | \
		ubiupdatevol /dev/$kern_ubivol -s $kernel_length -

	local root_ubidev="$( nand_find_ubi "$CI_BUF_ROOTPART" )"
	local root_ubivol="$(nand_find_volume $root_ubidev rootfs)"
	tar xf $tar_file ${board_dir}/root -O | \
		ubiupdatevol /dev/$root_ubivol -s $rootfs_length -

	buffalo_do_upgrade_success
}

# Recognize type of passed file and start the upgrade process
platform_do_upgrade_buffalo() {

	local file_type=$(identify $1)

	[ ! "$(find_mtd_index "$CI_BUF_ROOTPART")" ] && CI_BUF_ROOTPART="rootfs"

	case "$file_type" in
		"ubi" |\
		"ubifs")
			echo "not compatible sysupgrade file."
			return 1
			;;
		*)		buffalo_upgrade_tar $1;;
	esac
}
