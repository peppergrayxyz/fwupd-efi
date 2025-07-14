#!/usr/bin/env sh

set -eu

if [ $# -lt 2 ]; then
    echo "usage ARCH= $0 <distro> <features...>" >&2
    exit 1
fi

distro="$1"
shift 1
features="$*"

arch="${ARCH:-"$(uname -m)"}"

echo "Installer started:"
echo "- features: $features"
echo "- arch    : $arch"

if [ -z "$distro" ]; then
  echo "Guessing distro by package manager" 
  if   command -v apt    > /dev/null 2>&1; then distro='debian'; 
  elif command -v dnf    > /dev/null 2>&1; then distro='fedora'; 
  elif command -v pacman > /dev/null 2>&1; then distro='archlinux'; 
  elif command -v apk    > /dev/null 2>&1; then distro='alpine'; 
  elif command -v emerge > /dev/null 2>&1; then distro='gentoo'; 
  fi
fi
case "$distro" in
  ubuntu*|debian*|fedora*|archlinux*|alpine*) ;;
  *) echo "$0: unsupported distribution '$distro'" >&2
     exit 1
  ;;
esac
echo "- distro  : $distro"

case "$distro" in
  "ubuntu"*|\
  "debian"*)  install_tool="apt update -y && apt install -y" ;;
  "fedora"*)  install_tool="dnf -y update && dnf -y install" ;;
  "arch"*)    install_tool="pacman -Sy --noconfirm" ;;
  "alpine"*)  install_tool="apk update && apk add" ;;
  *)
    echo "$0: unsupported distribution '$distro'" >&2
    exit 1
    ;;
esac

edk2rpm=""
case "$arch" in
    "x86_64") ekd2package="edk2-ovmf"      ;;
    "i386"|\
    "i686")   ekd2package="edk2-ovmf-ia32" ;;
    "arm")    ekd2package="edk2-arm"       ;;
    *)        ekd2package="edk2-$arch"     ;;
esac


case "$arch" in
    "i686")   qemu_system="qemu-system-i386"  ;;
    "arm"*)   qemu_system="qemu-system-arm"   ;;
    *)        qemu_system="qemu-system-$arch" ;;
esac

packages=""
for f in $features; do
  case "$f" in
    "base") case "$distro" in
        "ubuntu"*|\
        "debian"*) packages="$packages pkg-config python3 ninja-build meson" ;;
        "fedora"*) packages="$packages pkg-config python3 ninja-build meson" ;;
        "arch"*)   packages="$packages pkg-config python3 ninja meson"       ;;
        "alpine"*) packages="$packages python3 ninja meson"                  ;;
      esac ;;
    "gnu") case "$distro" in
        "alpine"*) packages="$packages gcc musl-dev binutils" ;;
        *)         packages="$packages gcc binutils" ;;
      esac ;;
    "llvm")        packages="$packages llvm clang lld" ;;
    "qemu") case "$distro" in
        "arch"*)   packages="$packages qemu-system-base" ;;
        *)         packages="$packages $qemu_system"  ;;
      esac ;;
    "edk2") case "$distro" in
        "ubuntu"*|\
        "debian"*) apt-cache show "$ekd2package" > /dev/null && packages="$packages $ekd2package"; ;;
        "fedora"*) dnf info -q    "$ekd2package" > /dev/null && packages="$packages $ekd2package"; ;;
        "arch"*)   pacman -Si     "$ekd2package" > /dev/null && packages="$packages $ekd2package"; ;;
        "alpine"*) apk info       "$ekd2package" > /dev/null && packages="$packages $ekd2package"; ;;
      esac 
      edk2rpm=1;
      case "$distro" in
        *)         packages="$packages wget tar xz binutils" ;;
      esac ;;
    "buildpkg") case "$distro" in
        "ubuntu"*|\
        "debian"*) packages="$packages devscripts mingw-w64-tools gobject-introspection" ;;
        "fedora"*) packages="$packages git jq fedora-packager rpmdevtools pesign" ;;
        *) echo "$0: buildpkg is not configured for '$distro'" >&2; 
           exit 1 ;;
      esac ;;
    "py3pe") case "$distro" in
        "arch"*)   packages="$packages python-pefile"  ;;
        "alpine"*) packages="$packages py3-pefile"  ;;
        *)         packages="$packages python3-pefile" ;;
      esac ;;
    "gnuefi") case "$distro" in
        "fedora"*) packages="$packages gnu-efi-devel"  ;;
        "alpine"*) packages="$packages gnu-efi-dev"  ;;
        *)         packages="$packages gnu-efi" ;;
      esac ;;
    *)  echo "$0: unkonw feature '$f'" >&2; 
        exit 1 
    ;;
  esac
done

install_cmd="$install_tool$packages"
echo "- command : $install_cmd"
eval "$install_cmd" || return 1

## EDK2
#
# Download and install latest 
# - EDK2-OMVF  from Fedora
# - UEFI-Shell from Github
#
# EKD2_BASE   where to install      default: /
# EDK2_FORCE  override if present   default: unset
#
if [ -n "$edk2rpm" ]; then

  WGET="wget -qO"

  download_pkg()
  {
    download_dst="$1"
    download_url="$2"
    echo "- url    : $download_url"
    if ! $WGET "$download_dst" "$download_url"; then
      echo "download failed" >&2
      return 1;
    fi
  }

  create_link()
  {
    create_link_target="$1"
    create_link_link="$2"
    echo "$(dirname "$create_link_link")/$create_link_target"
    if ! { [ -f "$create_link_target" ] || [ -f "$(dirname "$create_link_link")/$create_link_target" ]; }; then
      echo "$create_link_target does not exist" >&2
      return 1
    fi
    ln -vfs "$create_link_target" "$create_link_link"
  }

  getOvmfPkg()
  {
    pkg="$1"
    pkg_dir="$2"

    pkg_base_url="http://ftp.debian.org/debian/pool/main/e/edk2"
    pkg_release="2025.02-8_all"
    pkg_name="${pkg}_$pkg_release"
    pkg_url="$pkg_base_url/$pkg_name.deb"
    pkg_path="$pkg_dir/$pkg.deb"
  

    echo "- pkg    : $pkg"
    echo "- release: $pkg_release"
    echo "- pkg-url: $pkg_url"
    echo "- file   : $pkg_path"
  
    if ! $WGET "$pkg_path" "$pkg_url"; then
      echo "download failed $?" >&2
      return 1;
    fi
  }

  createOMVFLinks()
  {
    ovmflink_arch="$1"
    ovmflink_dir="$2"

    case "$ovmflink_arch" in
        "x86_64")
            ovmf_code="OVMF/OVMF_CODE_4M.fd"
            ovmf_vars="OVMF/OVMF_VARS_4M.fd"
        ;;
        "i386"|\
        "i686")
            ovmf_code="OVMF/OVMF32_CODE_4M.fd"
            ovmf_vars="OVMF/OVMF32_VARS_4M.fd"
        ;;
        "aarch64")
            ovmf_code="AAVMF/AAVMF_CODE.fd"
            ovmf_vars="AAVMF/AAVMF_VARS.fd"
        ;;
        "arm"*)
            ovmf_code="AAVMF/AAVMF32_CODE.fd"
            ovmf_vars="AAVMF/AAVMF32_VARS.fd"
        ;;
        "loongarch64")
            ovmf_code="qemu-efi-loongarch64/QEMU_EFI.fd"
            ovmf_vars="qemu-efi-loongarch64/QEMU_VARS.fd"
        ;;
        "riscv64")
            ovmf_code="qemu-efi-riscv64/RISCV_VIRT_CODE.fd"
            ovmf_vars="qemu-efi-riscv64/RISCV_VIRT_VARS.fd"
        ;;
        *) 
            ovmf_code="qemu-efi-$ovmflink_arch/QEMU_EFI.fd"
            ovmf_vars="qemu-efi-$ovmflink_arch/QEMU_VARS.fd"
    esac

    create_link "../../$ovmf_code" "$ovmflink_dir/code.fd" || return $?
    create_link "../../$ovmf_vars" "$ovmflink_dir/vars.fd" || return $?
  }
  installOVMF()
  {
    ovmf_pkg_arch="$1"
    ovmf_temp_dir="$2"
    ovmf_inst_dir="$3"
    ovmf_link_dir="$4"

    case "$ovmf_pkg_arch" in        
        "i386"|\
        "i686")   ovmf_pkg="ovmf-ia32"                ;;
        "x86_64") ovmf_pkg="ovmf"                     ;;
        *)        ovmf_pkg="qemu-efi-$ovmf_pkg_arch"  ;;
    esac

    echo "Download deb for $ovmf_pkg:"
    ovmf_work_dir="$ovmf_temp_dir/$ovmf_pkg"
    mkdir -p "$ovmf_work_dir"
    getOvmfPkg "$ovmf_pkg" "$ovmf_work_dir" || return $?

    echo "Install $ovmf_pkg:"
    ar vx "$ovmf_work_dir/$ovmf_pkg.deb" --output="$ovmf_work_dir"       || return $?
    tar -xvf "$ovmf_work_dir/data.tar.xz" --directory="$ovmf_inst_dir/"  || return $?
    rm -rf "$ovmf_work_dir" 
    
    echo "Create links:"  
    mkdir -p "$ovmf_link_dir"
    createOMVFLinks "$ovmf_pkg_arch" "$ovmf_link_dir" || return $?
  }

  createUefiShellLinks()
  {
    uefi_shell_link_arch="$1"
    uefi_shell_link_dir="$2"
    create_link "shell$uefi_shell_link_arch.efi" "$uefi_shell_link_dir/shell.efi" || return 1
  }

  installUefiShell()
  {
    uefi_shell_arch="$1"
    uefi_shell_inst_dir="$2"
    
    uefi_shell_release="25H1"
    uefi_shell_pkg="shell$uefi_shell_arch.efi"

    uefi_shell_source="https://github.com/pbatard/UEFI-Shell/releases/download/$uefi_shell_release"
    uefi_shell_url="$uefi_shell_source/$uefi_shell_pkg"

    echo "Download UEFI-Shell ($uefi_shell_pkg):"
    download_pkg "$uefi_shell_inst_dir/$uefi_shell_pkg" "$uefi_shell_url" || return $?

    echo "Create links:"  
    createUefiShellLinks "$uefi_shell_arch" "$uefi_shell_inst_dir" || return $?
  }

  case "$arch" in
      "x86_64")   uefi_arch="x64"                 ;;
      "i386"|\
      "i686")     uefi_arch="ia32";   arch="i386" ;;
      "arm"*)     uefi_arch="arm";    arch="arm"  ;;
      "aarch64")  uefi_arch="aa64"                ;;
      *)          uefi_arch="$arch"               ;;
  esac

  work_dir="${EKD2_BASE:-""}"
  force="${EDK2_FORCE:-""}"
  install_dir="$work_dir"
  temp_dir="$work_dir/tmp"
  link_dir="$install_dir/usr/share/edk2/$uefi_arch"

  echo "OVMF"
  if ! createOMVFLinks "$arch" "$link_dir" || [ -n "$force" ] ; then
    installOVMF "$arch" "$temp_dir" "$install_dir" "$link_dir" || return $?
  fi

  echo "UEFI-Shell"
  if ! createUefiShellLinks "$uefi_arch" "$link_dir" || [ -n "$force" ]; then
    installUefiShell "$uefi_arch" "$link_dir" || return $?
  fi
fi

true
