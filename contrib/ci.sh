#!/bin/bash
set -e
shopt -s extglob
rm -rf build/

# disable the safe directory feature
if command -v git > /dev/null 2>&1; then 
    git config --global safe.directory "*"; 
fi

set -x
# Build
if [ -z "$CI_BUILDPKG" ]; then
    # normal build
    if [ -n "$LLVM" ]; then export CC='clang' CC_LD='lld' CFLAGS='-fuse-ld=lld' LDFLAGS='-fuse-ld=lld' AR='llvm-ar' STRIP='llvm-strip' OBJCOPY='llvm-objcopy'; fi
    # 
    meson build "$@"
    ninja -C build
else
    # package build
    case "$CI_DISTRO" in
        fedora*)
            meson build
            VERSION=`meson introspect build --projectinfo | jq -r .version`
            RPMVERSION=${VERSION//-/.}
            sed "s,#VERSION#,$RPMVERSION,;
                s,#BUILD#,1,;
                s,#LONGDATE#,`date '+%a %b %d %Y'`,;
                s,#ALPHATAG#,alpha,;
                s,Source0.*,Source0:\tfwupd-efi-$VERSION.tar.xz," \
                contrib/fwupd-efi.spec.in > build/fwupd-efi.spec
            if [ -n "$CI" ]; then
                sed -i "s,enable_ci 0,enable_ci 1,;" build/fwupd-efi.spec
            fi
            ninja -C build dist
            mkdir -p $HOME/rpmbuild/SOURCES/
            mv build/meson-dist/fwupd-efi-$VERSION.tar.xz $HOME/rpmbuild/SOURCES/
            rpmbuild -ba build/fwupd-efi.spec
            mkdir -p dist
            cp $HOME/rpmbuild/RPMS/*/*.rpm dist
        ;;
        debian*)
            export DEBFULLNAME="CI Builder"
            export DEBEMAIL="ci@travis-ci.org"
            VERSION=`head meson.build | grep ' version :' | cut -d \' -f2`
            mkdir -p build
            cp -lR !(build|dist|venv) build/
            pushd build
            mv contrib/debian .
            sed s/quilt/native/ debian/source/format -i
            #build the package
            EDITOR=/bin/true dch --create --package fwupd-efi -v $VERSION "CI Build"
            debuild --no-lintian --preserve-envvar CI --preserve-envvar CC \
                --preserve-envvar QUBES_OPTION
        ;;
        *)
            echo "$0: unsupported distribution '$CI_DISTRO'" >&2
            exit 1
        ;;
    esac
fi
