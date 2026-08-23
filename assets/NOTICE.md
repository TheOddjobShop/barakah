# Third-party assets and licensing

The MIT licence in [`LICENSE`](../LICENSE) covers this repository's source code.
This file records everything else.

## Bundled audio

### `Resources/Athan/Adhan.m4a`

The build embeds this file directly in the Barakah executable. At runtime it is
materialised in the user's cache directory because AVAudioPlayer requires a file
URL. It is still the same asset, with the following provenance and licence:

```
"Muslim calling to prayer" by Aishatu98
Source:  https://commons.wikimedia.org/wiki/File:Muslim_calling_to_prayer.ogg
License: CC0 1.0 Universal (Public Domain Dedication)
         https://creativecommons.org/publicdomain/zero/1.0/

Attribution is not required under CC0. It is given here as a courtesy.
Modifications: normalised to -16 LUFS with a two-pass loudnorm, downmixed to
mono, and re-encoded to AAC at 96 kbps.
```

Verified against the Wikimedia Commons API before bundling: `LicenseShortName`
is `CC0`, `AttributionRequired` is `false`, and `Restrictions` is empty. CC0 is
a dedication to the public domain, so redistribution inside this app is
permitted without condition.

Note the two layers being separated here. The **text** of the adhan is roughly
1400 years old and is in the public domain by age. The **recording** is a
separate copyrightable work, and this one is free only because its recordist
dedicated it. That is why one specific file is bundled rather than any adhan
recording that happens to be downloadable.

### Why this one

Amateur field recordings whose recordist dedicated them are, in practice, the
only freely-licensed adhan audio that exists. No mosque, waqf, broadcaster, or
well-known muezzin has released a recording under a free licence. Sites that
offer adhan downloads at no cost are offering them to *listen* to — free of
charge is not the same as free to redistribute, and several such sites carry an
explicit "all rights reserved".

Two categories were checked and rejected:

- **License-laundered uploads.** Several Wikimedia files tagged CC0 or CC BY-SA
  are re-encoded commercial recordings relabelled as own work. `Beautiful
  adhan.ogg` and `Azan.ogg` both measure around −9 LUFS with a hard spectral
  cutoff near 10 kHz — the fingerprint of a low-bitrate MP3, not a field
  recording. The bundled file shows no such cutoff and shares a consistent
  high-band signature with its uploader's other recordings, which is what
  genuine own-work looks like.
- **Category errors.** `Call to prayer by Sabah Fakhry.mp3` is tagged public
  domain on the grounds that "Adhan has been in effect since c.622 A.D." — the
  exact conflation of text and recording described above. It is a 1985
  performance by a singer who died in 2021, sourced from YouTube.

Also rejected: Pixabay, whose licence forbids redistributing an unmodified file
"on a standalone basis", which is precisely what bundling one would be.

### What other apps do

The surveyed open-source prayer apps bundle named-reciter recordings — Abdul
Basit, Mishary Rashid al-Afasy, al-Minshawi, "Adhan Makkah" — under a blanket
MIT or GPL code licence with no audio licence and no attribution. One ships 47
such files. That is a habit rather than a defence, and this project does not
follow it.

## Using your own recording

Barakah plays any audio file you point it at. Two ways in:

- **Settings → Athan → Choose a file…** — pick a file anywhere on disk.
- Drop a file into `~/Library/Application Support/Barakah/Athan/` and it appears
  in the sound list straight away, no restart needed. `.m4a`, `.mp3`, `.caf`,
  `.wav`, `.aiff` and `.ogg` all work.

Barakah uses the embedded recording by default and level-matches any replacement
you give it on playback, so no manual preparation is needed.

Whatever you put there stays on your machine. It is not part of this repository
and is not included in any release.

## Code dependencies

| Dependency | Licence | Used for |
|---|---|---|
| [adhan-swift](https://github.com/batoulapps/adhan-swift) | MIT | Prayer time calculation |

Note that Batoul Apps open-sourced the *calculation library* under MIT. Their
Guidance app's adhan audio is proprietary and is not available under that
licence — a distinction several projects have got wrong.

## Artwork

`assets/icon.svg` and `assets/barakah.svg` are original vector art created for
this project, and are covered by the repository's MIT licence.
