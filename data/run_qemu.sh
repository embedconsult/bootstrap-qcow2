#!/bin/bash
cd $(dirname $0)
if [ "$(uname -m)" == "x86_64" ]; then
	qemu-system-x86_64 \
		-cpu host -enable-kvm -smp 2 -m 1G \
		-nographic \
		-bios ./bios.bin \
		-drive file=blabl-space-20250612.qcow2 \
		-netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
		-chardev pty,id=char0 -serial chardev:char0 ;
else
	qemu-system-x86_64 \
		-m 1G \
		-nographic \
		-bios ./bios.bin \
		-drive file=blabl-space-20250612.qcow2 \
		-netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
		-chardev pty,id=char0 -serial chardev:char0 ;
fi
