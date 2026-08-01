#!/usr/bin/env sh
set -eu

if [ $# -lt 1 ]; then
    echo "usage DISTRO= $0 <features...>" >&2
    exit 2
fi

features="$*"
distro="${DISTRO:-}"

echo "Installer started:"
echo "- features: $features"

if [ -z "$distro" ]; then
  echo "Guessing distro by package manager"
  if   command -v apt    > /dev/null 2>&1; then distro='debian';
  elif command -v dnf    > /dev/null 2>&1; then distro='fedora';
  elif command -v pacman > /dev/null 2>&1; then distro='archlinux';
  elif command -v apk    > /dev/null 2>&1; then distro='alpine';
  fi
fi
case "$distro" in
  ubuntu*|debian*|fedora*|archlinux*|alpine*) ;;
  *) echo "$0: unsupported distribution '$distro'" >&2
     exit 2
  ;;
esac
echo "- distro  : $distro"

case "$distro" in
  "ubuntu"*|\
  "debian"*)  update="apt update -y"; pkgadd="apt install -y" ;;
  "fedora"*)  update="dnf -y update"; pkgadd="dnf -y install" ;;
  "arch"*)    update="";              pkgadd="pacman -Sy --noconfirm" ;;
  "alpine"*)  update="";              pkgadd="apk add --no-cache" ;;
  *)
    echo "$0: unsupported distribution '$distro'" >&2
    exit 2
    ;;
esac

packages=""
pip_pkgs=""
src_pkgs=""

## build dependencies
for f in $features; do
  case "$f" in

    # toolchain
    "base") case "$distro" in
        "ubuntu"*|\
        "debian"*) packages="$packages pkg-config python3 meson ninja-build" ;;
        "fedora"*) packages="$packages pkg-config python3 meson ninja-build" ;;
        "arch"*)   packages="$packages pkg-config python3 meson ninja"       ;;
        "alpine"*) packages="$packages pkgconfig  python3 meson ninja"       ;;
      esac ;;

    "gnu") case "$distro" in
        "alpine"*) packages="$packages gcc musl-dev binutils" ;;
        *)         packages="$packages gcc binutils" ;;
      esac ;;

    "llvm")        packages="$packages llvm clang lld compiler-rt" ;;

    # deps
    "gnuefi") case "$distro" in
        "fedora"*) packages="$packages gnu-efi-devel"  ;;
        "alpine"*) packages="$packages gnu-efi-dev"  ;;
        *)         packages="$packages gnu-efi" ;;
      esac ;;

    "py3pe") case "$distro" in
        "arch"*)   packages="$packages python-pefile"  ;;
        "alpine"*) packages="$packages py3-pefile"  ;;
        *)         packages="$packages python3-pefile" ;;
      esac ;;

    # optional deps
    "genpeimg") case "$distro" in
        "fedora"*|\
        "ubuntu"*|\
        "debian"*) packages="$packages mingw-w64-tools" ;;
        *)         packages="$packages wget make"
                   src_pkgs="mingw-w64-tools" ;;
      esac ;;

    "uswid") case "$distro" in
        "fedora"*) packages="$packages python-uswid"  ;;
        "alpine"*) packages="py3-pip py3-cbor2 py3-lxml py3-pefile"; pip_pkgs="uswid" ;;
        *)         packages="py3-pip" pip_pkgs="uswid" ;;
      esac ;;

    *)  echo "$0: unknown feature '$f'" >&2;
        exit 2
    ;;
  esac
done

if [ -n "$update" ]; then
  echo "- update  : $update"
  $update
fi

if [ -n "$packages" ]; then
  echo "- install : $pkgadd $packages"
  # shellcheck disable=SC2086
  $pkgadd $packages
fi

if [ -n "$pip_pkgs" ]; then
  echo "- pip     : $pip_pkgs"
  # shellcheck disable=SC2086
  python3 -m pip install --break-system-packages --no-deps --no-cache-dir $pip_pkgs
fi

if [ -n "$src_pkgs" ]; then
  echo "- src     : $src_pkgs"

  for pkg in $src_pkgs; do
    echo "> $pkg"

    case "$pkg" in

    # Package request: https://gitlab.alpinelinux.org/alpine/aports/-/work_items/18382
    "mingw-w64-tools")

      case "$distro" in
        # Bug https://gitlab.alpinelinux.org/alpine/aports/-/work_items/18383
        "alpine"*)
          if ${CC:-cc} --version 2>&1 | grep -qi 'clang'; then addflags=true
          elif gcc --version 2>&1;                        then addflags=false
          elif clang --version 2>&1;                      then addflags=true
          else                                                 addflags=false; fi

          if $addflags; then 
            export LDFLAGS="${LDFLAGS:+$LDFLAGS }-fuse-ld=lld --rtlib=compiler-rt";
          fi
        ;;
      esac

      pkgver="14.0.0"
      pkgname="mingw-w64-v${pkgver}"
      tarname="${pkgname}.tar.bz2"
      wget "https://sourceforge.net/projects/mingw-w64/files/mingw-w64/mingw-w64-release/$tarname" -O $tarname
      echo "6eaf921d9eb987d3820b364ea9775bc19b965ec81490b6fdd716526c28e1995c  $tarname" | sha256sum -c -

      tar -xf $tarname
      oldpath=$(pwd)
      mkdir -p "$pkgname/build" && cd "$pkgname/build"

      ../mingw-w64-tools/genpeimg/configure --prefix=/usr/local || {
          status=$?
          logfile="config.log"
          [ -f "$logfile" ] && cat "$logfile"
          exit "$status"
      }

      make install || {
          status=$?
          logfile="config.log"
          [ -f "$logfile" ] && cat "$logfile"
          exit "$status"
      }

      cd "$oldpath"
    ;;

    *)  echo "unknown package '$pkg'"; exit 2 ;;
    esac
  done
fi
