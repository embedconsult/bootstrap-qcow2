#!/bin/bash
TARGET="${1:-x86_64}"
cd $(dirname $0)
if [ "$TARGET" == "arm" ]; then
	qemu-system-aarch64 \
			-machine virt \
			-m 1G \
			-cpu max \
			-nographic \
			-drive file=biosarm.bin,format=raw,if=pflash,readonly=on \
			-drive file=blabl-space-20250612.qcow2 \
			-netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
			-chardev pty,id=char0 -serial chardev:char0 ;
else
	if [ "$(uname -m)" == "x86_64" ]; then
		qemu-system-x86_64 \
			-cpu host -enable-kvm -smp 2 \
			-m 1G \
			-nographic \
			-bios ./biosx86.bin \
			-drive file=blabl-space-20250612.qcow2 \
			-netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
			-chardev pty,id=char0 -serial chardev:char0 ;
	else
		qemu-system-x86_64 \
			-bios ./biosx86.bin \
			-m 1G \
			-nographic \
			-drive file=blabl-space-20250612.qcow2 \
			-netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
			-chardev pty,id=char0 -serial chardev:char0 ;
	fi
fi
