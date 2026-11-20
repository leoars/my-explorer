# Application icon

`AppIcon.icns` and `AppIcon.png` are original My Explorer artwork, licensed under Apache-2.0 with this repository. The yellow folder and blue accents follow the familiar file-manager visual vocabulary. No Microsoft artwork is embedded.

The editable vector source is `scripts/generate-app-icon.swift`, using Core Graphics paths and gradients. Regenerate from the repository root on macOS:

```sh
swift scripts/generate-app-icon.swift
iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns
```

The iconset includes 16, 32, 128, 256, and 512 point icons at 1x and 2x. The build copies the committed `.icns` into the application bundle, where `CFBundleIconFile` references it.

File-row icons are supplied at runtime by `NSWorkspace.icon(forFile:)`. They reflect the user's installed application associations, custom icons, bundles, and symbolic links. These system/application icons are not redistributed as repository assets. Regular navigable folders retain the yellow folder symbol used by the Explorer interface.
