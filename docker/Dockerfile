FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates debian-archive-keyring live-build python3 \
      xorriso squashfs-tools mtools dosfstools isolinux syslinux-common \
      grub-pc-bin grub-efi-amd64-bin \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
