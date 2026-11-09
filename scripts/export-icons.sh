#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source_icon=branding/joy-icon.png

magick "$source_icon" -resize 512x512 apps/joy/assets/joy-icon.png
magick "$source_icon" -define icon:auto-resize=256,128,64,48,32,24,16 apps/joy/windows/runner/resources/app_icon.ico

for entry in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  density="${entry%:*}"
  size="${entry#*:}"
  magick "$source_icon" -resize "${size}x${size}" "apps/joy/android/app/src/main/res/mipmap-$density/ic_launcher.png"
done

for size in 16 32 64 128 256 512 1024; do
  magick "$source_icon" -resize "${size}x${size}" "apps/joy/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png"
done
