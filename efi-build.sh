crystal build src/hello-efi.cr --prelude=empty --cross-compile --target x86_64-unknown-efi --static --release --no-debug -p --error-trace --mcmodel kernel -Dskip_crystal_compiler_rt -Dwithout_iconv
