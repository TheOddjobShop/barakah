# Third-party assets and licensing

The MIT licence in [`LICENSE`](../LICENSE) covers this repository's source code.
This file records everything else.

## Bundled audio: none

**Barakah ships no adhan recording.** The default athan sound is a bell
synthesised at runtime by
[`ChimeSynthesiser.swift`](../Sources/Barakah/Services/ChimeSynthesiser.swift) —
no audio file exists in this repository, and none is downloaded unless you ask
for one.

That is a deliberate decision, and it is worth explaining, because almost every
other open-source prayer app does the opposite.

### Why

The *text* of the adhan is roughly 1400 years old and unquestionably in the
public domain. Nobody can claim rights in the words. But a **recording** of the
adhan carries two separate, live copyrights:

1. the **performer's rights** in the muezzin's vocal performance, and
2. the **sound recording copyright** owned by whoever fixed it — the recordist,
   the mosque, or a producer.

In the United States sound recordings are federally protected and, under the
Music Modernization Act, pre-1972 recordings are protected for up to 95 years
from publication. In the EU, phonograms get 70 years. So *every adhan recording
made in living memory is copyrighted*, however ancient the words are.

No mosque, waqf, broadcaster, or well-known muezzin has issued an explicit free
licence for a recording. Not the Haramain authorities, not Diyanet, not any of
the reciters whose names appear bundled inside other apps. The free adhan audio
that genuinely exists is amateur field recordings where the *recordist*
dedicated their own fixation to the public domain.

### What other apps do

A survey of the open-source macOS and mobile prayer apps found the same pattern
everywhere: named-reciter recordings — Abdul Basit, Mishary Rashid al-Afasy,
al-Minshawi, "Adhan Makkah", "Adhan Madinah" — bundled under a blanket MIT or
GPL code licence with **no audio licence and no attribution at all**. One app
ships 47 such files. Another ships ripped iOS system sounds. This is a habit
rather than a defence, and it is not one worth copying.

Two things are also worth flagging for anyone tempted by an obvious-looking
source:

- Several Wikimedia Commons files tagged CC0 or CC BY-SA are **license
  laundering**. `Beautiful adhan.ogg` and `Azan.ogg` both measure around
  −9 LUFS with a hard spectral cutoff near 10 kHz — the fingerprint of a
  low-bitrate MP3 re-encoded and relabelled as own work, not a field recording.
- `Call to prayer by Sabah Fakhry.mp3` is tagged public domain with the
  justification "Adhan has been in effect since c.622 A.D." That is exactly the
  category error described above: it is a 1985 recording by a singer who died in
  2021, sourced from YouTube.
- Pixabay's licence forbids redistributing an unmodified file "on a standalone
  basis", which is precisely what bundling one in a repository would be.

## Using your own recording

Barakah plays any audio file you point it at. Two ways in:

- **Settings → Athan → Choose a file…** — pick a file anywhere on disk.
- Drop a file into `~/Library/Application Support/Barakah/Athan/` and it appears
  in the sound list straight away, no restart needed. `.m4a`, `.mp3`, `.caf`,
  `.wav`, `.aiff` and `.ogg` all work.

Barakah asks for a recording the first time it runs, and level-matches whatever
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
