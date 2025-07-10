#!/bin/sh
set -exuo

case "$CI_DISTRO" in
  ubuntu*|debian*)
    apt-get update -y
    apt-get install -y build-essential cmake pkg-config python3 ninja-build meson
    apt-get install -y python3-pefile gnu-efi
    if case "$CI_DISTRO" in debian*) ;; *) false;; esac; then
        apt-get install -y devscripts mingw-w64-tools gobject-introspection
    fi
    ;;

  fedora*)
    dnf -y update
    dnf -y install make automake gcc python3 ninja-build meson
    dnf -y install python3-pefile gnu-efi-devel
    dnf -y install git jq fedora-packager rpmdevtools pesign
    ;;

  arch*)
    pacman -Sy --noconfirm archlinux-keyring
    pacman -Sy --noconfirm base-devel python3 ninja meson
    pacman -Sy --noconfirm python-pefile gnu-efi
    ;;

  gentoo*)
    echo ". /etc/profile" > /root/.bashrc
    emerge-webrsync --quiet
    emerge --quiet dev-python/pefile sys-boot/gnu-efi
    ;;

  alpine*)
    apk update
    apk add bash meson mingw-w64-tools
    case "$CI_DISTRO" in
      alpine-gcc*)  apk add build-base ;;
      alpine-llvm*) apk add clang lld  ;;
    esac
    apk add py3-pefile gnu-efi-dev
    ;;

  *)
    echo "$0: unsupported distribution '$CI_DISTRO'" >&2
    exit 1
    ;;
esac
