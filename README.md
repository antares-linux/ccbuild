## To-do
- [ ] test the build process for the included extra libraries from gcc's source tree
  - [x] libatomic
  - [x] libffi
  - [x] libgomp
  - [ ] libitm: fails at `/bin/sh ./libtool --tag=CXX   --mode=compile  -B$bdir/src/build-gcc/$TARGET/libstdc++-v3/{src,libsupc++}/.libs [...]  -c -o alloc_cpp.lo ../../../gcc-$pkg_gcc_version/libitm/alloc_cpp.cc` due to `-B` being a seemingly invalid flag; requires research
  - [x] libphobos
  - [x] libquadmath
  - [x] libssp
  - [x] libvtv
- [ ] patch gcc's bad fdpic generation for sh/j2, like in [musl-cross-make](https://github.com/richfelker/musl-cross-make)
- [ ] add patch sets for older versions (namely gcc)
- [ ] dependency checker script
- [ ] research ABIs of supported targets and tweak CPU_FLAGS as needed
- [ ] write readme/acknowledgements
