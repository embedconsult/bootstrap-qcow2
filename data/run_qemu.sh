#!/bin/bash
cd $(dirname $0)
qemu-system-x86_64 -cpu host -enable-kvm -m 1G -bios ./bios.bin -nographic -drive file=blabl-space-20250612.qcow2
