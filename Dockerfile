FROM alpine:latest AS hello
RUN apk add build-base cmake git python3 fossil crystal \
  llvm clang bison flex linux-headers elfutils-dev openssl-dev perl wget tar rsync lld20 bash \
  diffutils rsync gnu-efi-dev rust cargo rustup
WORKDIR /opt/hello-efi
COPY lib/efi.cr lib/
COPY shard.yml .
COPY spec/bootstrap-qcow2_spec.cr spec/
COPY spec/spec_helper.cr spec/
COPY src/bootstrap-qcow2.cr src/
COPY src/hello-efi.cr src/
#COPY lib/c lib/c
RUN crystal build --cross-compile --single-module --target aarch64-unknown-windows \
  -Dwithout_iconv -Dskip_crystal_compiler_rt -Dgc_none -Dwithout_openssl -Dwithout_zlib \
  src/hello-efi.cr
#  -Dwin32 \
RUN lld -flavor link -subsystem:efi_application -entry:efi_main hello-efi.obj -out:hello-efi.efi
