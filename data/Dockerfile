FROM alpine:latest AS rootfs
RUN apk add fossil linux-lts linux-firmware-none
#RUN apk add build-base cmake git python3
#WORKDIR /opt/linux
#RUN git clone https://github.com/torvalds/linux
#WORKDIR /opt/linux/linux
#RUN apk add llvm clang bison flex linux-headers elfutils-dev openssl-dev perl
#RUN git remote add lts https://github.com/gregkh/linux
#RUN make LLVM=1 ARCH=x86 x86_64_defconfig
#RUN make LLVM=1 ARCH=x86
#RUN apk add linux-lts grub genimage fossil
#RUN apk add linux-lts fossil

FROM alpine:latest AS genimage
RUN apk add bash genimage dosfstools mtools coreutils findutils e2fsprogs qemu-img efibootmgr
WORKDIR /tmp/genimage
COPY genimage.cfg .
COPY --from=rootfs / root/rootfs-arm
RUN mkdir -p images root/boot root/rootfs-arm root/rootfs-x86 \
  && touch root/boot/keep.txt root/rootfs-x86/keep.txt
RUN genimage

