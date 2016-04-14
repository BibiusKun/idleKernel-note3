#!/sbin/sh
# LazyFlasher boot image patcher script by jcadduono

tmp=/tmp/idlekernel

console=$(cat /tmp/console)
[ "$console" ] || console=/proc/$$/fd/1

cd "$tmp"
. config.sh

chmod -R 755 $bin
rm -rf $ramdisk $split_img
mkdir $ramdisk $split_img

print() {
	[ "$1" ] && {
		echo "ui_print - $1" > $console
	} || {
		echo "ui_print  " > $console
	}
	echo
}

abort() {
	[ "$1" ] && {
		print "Error: $1!"
		print "Aborting..."
	}
	exit 1
}

## start install methods

# dump boot and unpack the android boot image
dump_boot() {
	print "Dumping & unpacking original boot image..."
	dump_image "$boot_block" "$tmp/boot.img"
	[ $? = 0 ] || abort "Unable to read boot partition"
	$bin/unpackbootimg -i "$tmp/boot.img" -o "$split_img" || {
		abort "Unpacking boot image failed"
	}
}

# determine the format the ramdisk was compressed in
determine_ramdisk_format() {
	magicbytes=$(hexdump -vn2 -e '2/1 "%x"' $split_img/boot.img-ramdisk)
	case "$magicbytes" in
		425a) rdformat=bzip2; decompress=bzip2 ; compress="gzip -9c" ;; #compress="bzip2 -9c" ;;
		1f8b|1f9e) rdformat=gzip; decompress=gzip ; compress="gzip -9c" ;;
		0221) rdformat=lz4; decompress=$bin/lz4 ; compress="gzip -9c" ;; #compress="$bin/lz4 -9" ;;
		5d00) rdformat=lzma; decompress=lzma ; compress="gzip -9c" ;; #compress="lzma -c" ;;
		894c) rdformat=lzo; decompress=lzop ; compress="gzip -9c" ;; #compress="lzop -9c" ;;
		fd37) rdformat=xz; decompress=xz ; compress="gzip -9c" ;; #compress="xz --check=crc32 --lzma2=dict=2MiB" ;;
		*) abort "Unknown ramdisk compression format ($magicbytes)." ;;
	esac
	print "Detected ramdisk compression format: $rdformat"
	command -v "$decompress" || abort "Unable to find archiver for $rdformat"
}

# extract the old ramdisk contents
dump_ramdisk() {
	cd $ramdisk
	$decompress -d < $split_img/boot.img-ramdisk | cpio -i
	[ $? != 0 ] && abort "Unpacking ramdisk failed"
}

# execute all scripts in patch.d
patch_ramdisk() {
	print "Running ramdisk patching scripts..."
	find "$tmp/patch.d/" -type f | sort > "$tmp/patchfiles"
	while read -r patchfile; do
		print "Executing: $(basename "$patchfile")"
		env="$tmp/patch.d-env" sh "$patchfile" || {
			abort "Script failed: $(basename "$patchfile")"
		}
	done < "$tmp/patchfiles"
}

# build the new ramdisk
build_ramdisk() {
	print "Building new ramdisk..."
	cd $ramdisk
	find | cpio -o -H newc | $compress > $tmp/ramdisk-new
}

# build the new boot image
build_boot() {
	cd $split_img
	kernel=
	for image in zImage zImage-dtb Image Image-dtb Image.gz Image.gz-dtb; do
		if [ -s $tmp/$image ]; then
			kernel="$tmp/$image"
			print "Found replacement kernel $image!"
			break
		fi
	done
	[ "$kernel" ] || kernel="$(ls ./*-zImage)"
	if [ -s $tmp/ramdisk-new ]; then
		rd="$tmp/ramdisk-new"
		print "Found replacement ramdisk image!"
	else
		rd="$(ls ./*-ramdisk)"
	fi
	if [ -s $tmp/dtb.img ]; then
		dtb="$tmp/dtb.img"
		print "Found replacement device tree image!"
	else
		dtb="$(ls ./*-dt)"
	fi
	$bin/mkbootimg \
		--kernel "$kernel" \
		--ramdisk "$rd" \
		--dt "$dtb" \
		--second "$(ls ./*-second)" \
		--cmdline "$(cat ./*-cmdline)" \
		--board "$(cat ./*-board)" \
		--base "$(cat ./*-base)" \
		--pagesize "$(cat ./*-pagesize)" \
		--kernel_offset "$(cat ./*-kernel_offset)" \
		--ramdisk_offset "$(cat ./*-ramdisk_offset)" \
		--second_offset "$(cat ./*-second_offset)" \
		--tags_offset "$(cat ./*-tags_offset)" \
		-o $tmp/boot-new.img || {
			abort "Repacking boot image failed"
		}
}

# write the new boot image to boot block
write_boot() {
	print "Writing new boot image to memory..."
	flash_image "$boot_block" "$tmp/boot-new.img"
	[ $? = 0 ] || abort "Failed to write boot image! You may need to restore your boot partition"
}

## end install methods

## start boot image patching

dump_boot

determine_ramdisk_format

dump_ramdisk

patch_ramdisk

build_ramdisk

build_boot

write_boot

## end boot image patching
