#!/bin/sh
# Copyright (C) 2018 OpenWrt.org
#

. /lib/functions.sh

# 'firmware1' and 'firmware2' partition on NAND contains
# the kernel and fakerootfs. WXR-2533DHP uses the kernel
# image in 'firmware1'. However, U-Boot checks 'firmware1'
# and 'firmware2' images when booting, and if they are not
# match, do write back image to 'firmware1' from 'firmware2'.
CI_BUF_UBIPART="${CI_BUF_UBIPART:-firmware1}"
CI_BUF_UBIPART2="${CI_BUF_UBIPART2:-firmware2}"
KERN_VOLNAME="${KERN_VOLNAME:-kernel}"
FKROOT_VOLNAME="${FKROOT_VOLNAME:-ubi_rootfs}"

buffalo_upgrade_prepare_ubi() {
	local rootfs_length="$1"
	local rootfs_type="$2"

	# search first ubi partition
	local mtdnum1="$( find_mtd_index "$CI_BUF_UBIPART" )"
	if [ ! "$mtdnum1" ]; then
		echo "cannot find first ubi mtd partition $CI_BUF_UBIPART"
		return 1
	fi

	# search second ubi partition
	local mtdnum2="$( find_mtd_index "$CI_BUF_UBIPART2" )"
	if [ ! "$mtdnum2" ]; then
		echo "cannot find second ubi mtd partition $CI_BUF_UBIPART2"
	fi

	# search first ubi device (e.g. ubi0) from $CI_BUF_UBIPART
	local ubidev1="$( nand_find_ubi "$CI_BUF_UBIPART" )"
	if [ ! "$ubidev1" ]; then
		ubiattach -m "$mtdnum1"
		sync
		ubidev1="$( nand_find_ubi "$CI_BUF_UBIPART" )"
	fi

	# search second ubi device from $CI_BUF_UBIPART2
	local ubidev2="$( nand_find_ubi "$CI_BUF_UBIPART2" )"
	if [ ! "$ubidev2" ] && [ -n "$mtdnum2" ]; then
		ubiattach -m "$mtdnum2"
		sync
		ubidev2="$( nand_find_ubi "$CI_BUF_UBIPART2" )"
	fi

	# ubi device still not found
	if [ ! "$ubidev1" ]; then
		ubiformat /dev/mtd$mtdnum1 -y
		ubiattach -m "$mtdnum1"
		sync
		ubidev="$( nand_find_ubi "$CI_BUF_UBIPART" )"
	fi

	# get root/data ubi volume
	local kern_ubivol="$( nand_find_volume $ubidev1 $KERN_VOLNAME )"
	local fkroot_ubivol="$( nand_find_volume $ubidev1 $FKROOT_VOLNAME )"
	local root_ubivol="$( nand_find_volume $ubidev1 rootfs )"
	local data_ubivol="$( nand_find_volume $ubidev1 rootfs_data )"
	# (ubi_rootfs_data vol in stock firmware)
	local buf_data_ubivol="$( nand_find_volume $ubidev1 ubi_rootfs_data )"
	# (kernel vol in second partition)
	local kern2_ubivol="$( nand_find_volume $ubidev2 $KERN_VOLNAME )"

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
	[ "$kern_ubivol" ] && ubirmvol /dev/$ubidev1 -N $KERN_VOLNAME || true
	[ "$fkroot_ubivol" ] && ubirmvol /dev/$ubidev1 -N $FKROOT_VOLNAME || true
	[ "$root_ubivol" ] && ubirmvol /dev/$ubidev1 -N rootfs || true
	[ "$data_ubivol" ] && ubirmvol /dev/$ubidev1 -N rootfs_data || true
	[ "$buf_data_ubivol" ] && ubirmvol /dev/$ubidev1 -N ubi_rootfs_data || true

	# re-create fakerootfs volume and write backup image
	if ! ubimkvol /dev/$ubidev1 -N $FKROOT_VOLNAME -s $fkroot_length; then
		echo "cannot create fakeroot volume"
		return 1;
	else
		fkroot_ubivol="$( nand_find_volume $ubidev1 $FKROOT_VOLNAME )"
		echo "write fakeroot image to $fkroot_ubivol"
		ubiupdatevol /dev/$fkroot_ubivol -s $fkroot_length /tmp/fkroot.bin
	fi

	# re-create kernel volume
	if ! ubimkvol /dev/$ubidev1 -N $KERN_VOLNAME -s $kernel_length; then
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
	if ! ubimkvol /dev/$ubidev1 -N rootfs $root_size_param; then
		echo "cannot create rootfs volume"
		return 1;
	fi

	# create rootfs_data for non-ubifs rootfs
	if [ "$rootfs_type" != "ubifs" ]; then
		if ! ubimkvol /dev/$ubidev1 -N rootfs_data -m; then
			echo "cannot initialize rootfs_data volume"
			return 1
		fi
	fi

	# remove kernel volume from second ubi partition
	[ "$kern2_ubivol" ] && ubirmvol /dev/$ubidev2 -N $KERN_VOLNAME || true

	sync
	return 0
}

# Flash the UBI image to MTD partition
buffalo_upgrade_ubinized() {
	local ubi_file="$1"
	local mtdnum="$(find_mtd_index "$CI_BUF_UBIPART")"
	local mtdnum2="$(find_mtd_index "$CI_BUF_UBIPART2")"

	if [ ! "$mtdnum" ]; then
		echo "cannot find mtd device $CI_BUF_UBIPART"
		umount -a
		reboot -f
	fi

	# search second ubi device from $CI_BUF_UBIPART2
	local ubidev2="$( nand_find_ubi "$CI_BUF_UBIPART2" )"
	if [ ! "$ubidev2" ] && [ -n "$mtdnum2" ]; then
		ubiattach -m "$mtdnum2"
		sync
		ubidev2="$( nand_find_ubi "$CI_BUF_UBIPART2" )"
	fi

	# get kernel vol in second partition
	local kern2_ubivol="$( nand_find_volume $ubidev2 $KERN_VOLNAME )"

	# remove kernel volume from second ubi partition
	[ "$kern2_ubivol" ] && ubirmvol /dev/$ubidev2 -N $KERN_VOLNAME || true

	local mtddev="/dev/mtd${mtdnum}"
	ubidetach -p "${mtddev}" || true
	sync
	ubiformat "${mtddev}" -y -f "${ubi_file}"
	ubiattach -p "${mtddev}"

	CI_UBIPART="$CI_BUF_UBIPART"
	nand_do_upgrade_success
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

	CI_UBIPART="$CI_BUF_UBIPART"
	nand_do_upgrade_success
}

# Recognize type of passed file and start the upgrade process
platform_do_upgrade_buffalo() {

	local file_type=$(identify $1)

	[ ! "$(find_mtd_index "$CI_BUF_UBIPART")" ] && CI_BUF_UBIPART="rootfs"

	case "$file_type" in
		"ubi")
			CI_UBIPART="$CI_BUF_UBIPART"
			buffalo_upgrade_ubinized $1
			;;
		"ubifs")
			echo "not compatible sysupgrade file."
			return 1
			;;
		*)		buffalo_upgrade_tar $1;;
	esac
}
