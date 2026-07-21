# Fonts

Used only by `app/opengraph-image.tsx`. The site itself draws with the system
stack (SF Pro / SF Mono on macOS) and loads no webfonts — but Satori, which
rasterises the social card, has no system fonts to fall back on, so the card
ships its own.

These are the same families already named as fallbacks in `--font-sans` and
`--font-mono`, subsetted to the ~95 characters the card actually draws:

| File                     | Source                                                        | License   |
| ------------------------ | ------------------------------------------------------------- | --------- |
| `Inter-Regular.ttf`      | [Inter](https://fonts.google.com/specimen/Inter) 400           | OFL 1.1   |
| `Inter-SemiBold.ttf`     | Inter 600                                                      | OFL 1.1   |
| `JetBrainsMono-Medium.ttf` | [JetBrains Mono](https://fonts.google.com/specimen/JetBrains+Mono) 500 | OFL 1.1 |

To regenerate after a copy change that introduces new characters:

```sh
python3 -m fontTools.subset <full>.ttf \
  --text="$(cat charset.txt)" \
  --layout-features='kern,liga,calt,tnum' \
  --no-hinting --desubroutinize \
  --output-file=<name>.ttf
```

Subsetting is what keeps each file at ~30KB instead of ~300KB. A character that
isn't in the subset renders as a blank box in the card, so check the output
after editing the copy.
