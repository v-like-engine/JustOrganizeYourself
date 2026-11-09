# JOY icon

The JOY mark uses an upright wordmark and a clearly aligned three-row checklist. Charcoal lettering, a pale neutral background and a restrained sage accent identify a task organizer rather than a game. The geometry stays horizontal and vertical, with consistent spacing and no angled cards.

`joy-icon.png` is the full-resolution generated artwork. Application files are format/size exports of this artwork; the export step does not redraw the design.

To regenerate the Windows ICO, Android launcher PNGs, macOS icon set and Flutter asset, install ImageMagick on a development machine and run:

```sh
bash scripts/export-icons.sh
```

The Windows ICO includes 16, 24, 32, 48, 64, 128 and 256 pixel images. End users do not need ImageMagick or this script.

The Windows 0.1.1 release uses this upright checklist design in the EXE, installer and in-app navigation. All seven ICO images were verified inside both compiled Windows binaries; the packaged in-app PNG matches the exported artwork. The [Windows build and startup checks](https://github.com/v-like-engine/JustOrganizeYourself/actions/runs/42542587101) passed. Android was rebuilt with the same in-app artwork and launcher assets; macOS icon exports are provided without claiming a macOS runtime check.
