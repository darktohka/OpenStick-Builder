{ pkgs ? import <nixpkgs> {} }:

let
  crossGcc = pkgs.pkgsCross.aarch64-multiplatform.buildPackages.gcc;
in
pkgs.mkShell {
  buildInputs = [
    pkgs.simg2img          # android-sdk-libsparse-utils (img2simg/simg2img)
    pkgs.autoconf
    pkgs.automake
    pkgs.cmake
    pkgs.debian-archive-keyring
    pkgs.debootstrap
    pkgs.dtc               # device-tree-compiler
    pkgs.util-linux        # fdisk/sfdisk
    crossGcc               # gcc/g++-aarch64-linux-gnu
    pkgs.gcc-arm-embedded  # gcc-arm-none-eabi
    pkgs.libtool
    pkgs.gnumake
    pkgs.pkg-config
    pkgs.python3Packages.cryptography
    pkgs.python3Packages.pyasn1-modules
    pkgs.python3Packages.pycryptodome
    pkgs.qemu-user         # qemu-user-static
    pkgs.unzip
    pkgs.wget
  ];
}
