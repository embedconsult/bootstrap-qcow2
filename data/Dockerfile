FROM alpine:latest AS linux
RUN apk add build-base cmake git python3 fossil crystal \
  llvm clang bison flex linux-headers elfutils-dev openssl-dev perl wget tar rsync lld20 bash \
  diffutils rsync
WORKDIR /opt/linux
#RUN wget https://github.com/gregkh/linux/archive/refs/tags/v6.12.38.tar.gz -O linux.tar.gz
COPY ./linux.tar.gz /opt/linux
RUN tar xf linux.tar.gz --strip-components=1
RUN make LLVM=1 ARCH=x86 x86_64_defconfig
RUN scripts/config --enable CONFIG_EFI_STUB
RUN scripts/config --enable CONFIG_EFI
RUN scripts/config --set-val CONFIG_CMDLINE "root=/dev/sda1 console=ttyS0"
RUN make -j12 LLVM=1 ARCH=x86
RUN scripts/config --set-val CONFIG_CMDLINE "root=/dev/sda3 console=ttyS0"
RUN make -j12 LLVM=1 ARCH=x86
RUN make LLVM=1 ARCH=x86 INSTALL_HDR_PATH=/opt/linux/usr-x86 headers_install
RUN scripts/config --enable CONFIG_EARLY_PRINTK
RUN scripts/config --set-val CONFIG_CMDLINE "earlyprintk=serial,ttyS0,115200,keep console=ttyS0 root=PARTUUID=DC5A1A34-9C04-4E18-84D0-F45AE8483D93 debug ignore_loglevel"
RUN make -j12 LLVM=1 ARCH=x86
RUN cp /opt/linux/arch/x86/boot/bzImage /opt/linux/bootx64.efi

FROM --platform=amd64 alpine:latest AS rootfs-x86
RUN apk add bash fossil crystal

FROM --platform=arm64 alpine:latest AS rootfs-arm
RUN apk add bash fossil crystal

FROM alpine:latest AS genimage
RUN apk add bash genimage dosfstools mtools coreutils findutils e2fsprogs qemu-img efibootmgr
WORKDIR /tmp/genimage
RUN mkdir -p images root/boot/EFI/boot root/rootfs-arm root/rootfs-x86
COPY --from=rootfs-x86 / root/rootfs-x86
COPY --from=rootfs-arm / root/rootfs-arm
COPY --from=linux /opt/linux/usr-x86 root/rootfs-x86/usr
COPY --from=linux /opt/linux/bootx64.efi root/boot/EFI/boot/bootx64.efi
COPY genimage.cfg .
RUN genimage
RUN qemu-img convert -f raw -O qcow2 images/bootstrap.img images/bootstrap.qcow2

FROM linux AS edk2
RUN apk add nasm iasl ossp-uuid util-linux-dev
RUN cd /opt && git clone https://github.com/tianocore/edk2 \
  && cd /opt/edk2 && git checkout -b edk-stable202505 \
  && git submodule update --init
WORKDIR /opt/edk2
ENV CC="clang"
ENV CXX="clang++"
ENV LD="lld"
RUN make -C BaseTools/
RUN source edksetup.sh
#RUN export CLANG_BIN="$(dirname $(which clang))/"
#RUN build -p OvmfPkg/OvmfPkgIa32X64.dsc -a IA32 -a X64 -t CLANGPDB -b RELEASE

FROM genimage AS active
