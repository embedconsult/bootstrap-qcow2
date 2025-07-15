FROM alpine:latest AS llvm
RUN apk add build-base cmake git python3 fossil crystal \
  llvm clang bison flex linux-headers elfutils-dev openssl-dev perl wget tar rsync lld20 bash
WORKDIR /opt/linux
#RUN wget https://github.com/gregkh/linux/archive/refs/tags/v6.12.38.tar.gz -O linux.tar.gz
COPY ./linux.tar.gz /opt/linux
RUN tar xf linux.tar.gz --strip-components=1
RUN make LLVM=1 ARCH=x86 x86_64_defconfig
RUN scripts/config --enable CONFIG_EFI_STUB
RUN scripts/config --enable CONFIG_EFI
RUN scripts/config --set-val CONFIG_CMDLINE "root=/dev/sda2 console=tty0"
RUN make -j12 LLVM=1 ARCH=x86
RUN make LLVM=1 ARCH=x86 INSTALL_HDR_PATH=/opt/linux/usr-x86 headers_install
#WORKDIR /opt/edk2
#RUN wget https://github.com/tianocore/edk2/archive/refs/tags/edk2-stable202505.tar.gz -O edk2.tar.gz
#COPY ./edk2.tar.gz /opt/edk2

FROM --platform=amd64 alpine:latest AS rootfs-x86
RUN apk add bash fossil crystal

FROM --platform=arm64 alpine:latest AS rootfs-arm
RUN apk add bash fossil crystal

FROM alpine:latest AS genimage
RUN apk add bash genimage dosfstools mtools coreutils findutils e2fsprogs qemu-img efibootmgr
WORKDIR /tmp/genimage
COPY genimage.cfg .
RUN mkdir -p images root/boot/EFI/BOOT root/rootfs-arm root/rootfs-x86
COPY --from=llvm /opt/linux/arch/x86/boot/bzImage root/boot/EFI/BOOT/x86image.efi
COPY --from=llvm /opt/linux/usr-x86 root/rootfs-x86/usr
COPY --from=rootfs-x86 / root/rootfs-x86
COPY --from=rootfs-arm / root/rootfs-arm
RUN genimage

