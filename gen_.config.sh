#!/bin/bash
export PATH=$HOME/Clang/LLVM-22.1.2-Linux-X64/bin:$PATH
export LD_LIBRARY_PATH=$HOME/Clang/LLVM-22.1.2-Linux-X64/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

make ARCH=arm64 O=out \
    LLVM=1 \
    LLVM_IAS=1 \
    veux_defconfig
