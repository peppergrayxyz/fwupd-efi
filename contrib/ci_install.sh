#!/bin/sh

if [ -z "$CI_DISTRO" ]; then
  if   command -v apt    > /dev/null 2>&1; then CI_DISTRO='debian'; 
  elif command -v dnf    > /dev/null 2>&1; then CI_DISTRO='fedora'; 
  elif command -v pacman > /dev/null 2>&1; then CI_DISTRO='arch'; 
  elif command -v apk    > /dev/null 2>&1; then CI_DISTRO='alpine'; 
  elif command -v emerge > /dev/null 2>&1; then CI_DISTRO='gentoo'; 
  fi
fi

echo "Installing packages for $CI_DISTRO:" 

case "$CI_DISTRO" in
  ubuntu*|debian*)
    apt update -y
    apt install -y build-essential cmake pkg-config python3 ninja-build meson
    apt install -y python3-pefile gnu-efi
    [ -n "$LLVM" ]        && apt install -y llvm clang lld
    [ -n "$CI_BUILDPKG" ] && apt install -y devscripts mingw-w64-tools gobject-introspection
    ;;

  fedora*)
    dnf -y update
    dnf -y install make automake gcc python3 ninja-build meson
    dnf -y install python3-pefile gnu-efi-devel
    [ -n "$LLVM" ]        && dnf -y install llvm clang lld
    [ -n "$CI_BUILDPKG" ] && dnf -y install git jq fedora-packager rpmdevtools pesign
    ;;

  arch*)
    pacman -Sy --noconfirm archlinux-keyring
    pacman -Sy --noconfirm base-devel python3 ninja meson
    [ -n "$LLVM" ] && pacman -Sy --noconfirm llvm clang lld
    pacman -Sy --noconfirm python-pefile gnu-efi
    ;;

  alpine*)
    apk update
    apk add bash meson build-base
    [ -n "$LLVM" ] && apk add llvm clang lld
    apk add py3-pefile gnu-efi-dev
    ;;

  *)
    echo "$0: unsupported distribution '$CI_DISTRO'" >&2
    exit 1
    ;;
esac
