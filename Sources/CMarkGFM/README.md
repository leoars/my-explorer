# Vendored cmark-gfm

GitHub's CommonMark parser with its GitHub Flavored Markdown extensions (tables, strikethrough, autolinks, task lists, tag filter) and footnotes, used by the preview pane to read Markdown files. Only the parser is used; the renderers are compiled because the library references them, but the app never produces HTML from them.

Source: release `0.29.0.gfm.14` of https://github.com/github/cmark-gfm, commit `7fe8904ee31fa24b772ae565c4908b1394850de6` (archive SHA-256 `1c1acf50c5e9939e170b6e017ec06fcf94abeb383670b819d091a285b7ba11fe`). The files in `src` and `extensions` are unmodified, except that the public headers `cmark-gfm.h`, `cmark-gfm-extension_api.h` and `cmark-gfm-core-extensions.h` were moved to `include`, and `src/main.c` (the command-line tool) was left out.

CMake generates four files in the upstream build; they are written by hand here from the upstream templates: `src/config.h` (from `config.h.in`, with `stdbool.h`, `__builtin_expect` and `__attribute__` available), `include/cmark-gfm_version.h` (from `cmark-gfm_version.h.in`, version 0.29.0.gfm.14) and `include/cmark-gfm_export.h` (empty export macros: the library is linked statically). `include/CMarkGFM.h` is the module's umbrella header.

The license is in `COPYING` (BSD 2-Clause, with the notices for the parts derived from other projects). Other code in this target is Apache-2.0.
