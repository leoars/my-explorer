# System libarchive bridge

Links the libarchive shipped with macOS; no bundled binary or external runtime. The SDK ships its linker stub but omits public headers. `include/archive.h` and `include/archive_entry.h` are unmodified BSD-licensed public headers from Apple’s source distribution, commit `5649597e7975dd1f8c24ab0176f131f47a1cdae0`:

https://github.com/apple-oss-distributions/libarchive/tree/5649597e7975dd1f8c24ab0176f131f47a1cdae0/libarchive/libarchive

Their copyright and license notices are retained in each header. Other code in this target is Apache-2.0.
