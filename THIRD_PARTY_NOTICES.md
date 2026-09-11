# Third-party notices

t1-revive itself is MIT-licensed (see `LICENSE`). It builds and bundles, in a private
prefix, the free software listed below. Each component keeps its own licence.

Where to find the texts: in a source checkout, `vendor/src/<component>/COPYING*` after a
build; in the Arch package, `/usr/share/licenses/t1-revive/vendor/<component>/`. The pinned
commits, versions and licences are in `vendor/refs.env`; the modifications are the three
files in `vendor/patches/`; the corresponding-source statement shipped with binaries is
`vendor/SOURCES.template` → `SOURCES`.

Every licence identifier below was verified against the tree's `COPYING*` files **and** the
source-file headers of the pinned commit. Where the two disagree it is spelled out.

## Components

| component | upstream | licence | patched by t1-revive |
| --- | --- | --- | --- |
| libplist | https://github.com/libimobiledevice/libplist | LGPL-2.1-or-later | no |
| libimobiledevice-glue | https://github.com/libimobiledevice/libimobiledevice-glue | LGPL-2.1-or-later | no |
| libtatsu | https://github.com/libimobiledevice/libtatsu | LGPL-2.1-or-later | no |
| libirecovery | https://github.com/libimobiledevice/libirecovery | LGPL-2.1-only | yes — `vendor/patches/libirecovery.patch` |
| libusbmuxd | https://github.com/libimobiledevice/libusbmuxd | LGPL-2.1-or-later | no |
| libimobiledevice | https://github.com/libimobiledevice/libimobiledevice | LGPL-2.1-or-later AND GPL-2.0-or-later | no |
| usbmuxd | https://github.com/libimobiledevice/usbmuxd | GPL-2.0-only OR GPL-3.0-only | yes — `vendor/patches/usbmuxd.patch` |
| idevicerestore | https://github.com/libimobiledevice/idevicerestore | LGPL-2.1-or-later AND LGPL-3.0-or-later | yes — `vendor/patches/idevicerestore.patch` |

Notes on the four that are not a plain single identifier:

- **libplist** ships both `COPYING` (the GPL-2.0 text) and `COPYING.LESSER` (LGPL-2.1).
  Every source header, library and tool alike, says LGPL-2.1-or-later; the GPL text is
  present because the LGPL-2.1 refers to it.
- **libirecovery** headers read "made available under the terms of the GNU Lesser General
  Public License (LGPL) version 2.1", with no "or any later version" clause — so
  LGPL-2.1-**only**, not -or-later.
- **libimobiledevice** is LGPL-2.1-or-later throughout, except `tools/idevicesetlocation.c`,
  which is GPL-2.0-or-later. That tool is built and installed with the rest, hence the AND.
- **idevicerestore**'s source headers all say LGPL-2.1-or-later, while the repository's
  `COPYING` and README say LGPL-3.0. Both are named so no reader is misled.

The three patches are offered under the licence of the files they modify. They are the only
modifications: everything else is the unmodified upstream commit named in `refs.env`.

Autotools build machinery inside those trees (`m4/`, `config.guess`, `ltmain.sh`, …) carries
Free Software Foundation and libtool copyrights with the usual autoconf/libtool exceptions.
It is not shipped in the binary package and is not listed below.

## Copyright holders

Taken from the source headers of the pinned commits (shipped code only: `src/`, `tools/`,
`common/`, `include/`, `libcnary/`). Year ranges are the span found across each tree.

### libplist

```
Copyright (c) 2008-2010 Jonathan Beck
Copyright (c) 2011      Joshua Hill
Copyright (c) 2009-2020 Martin Szulecki
Copyright (c) 2007-2010 Michael G Schwern
Copyright (c) 2009-2026 Nikias Bassen
Copyright (c) 2010      Serge A. Zaitsev          (jsmn, bundled JSON parser)
Copyright (c) 2008      Zach C.
```

AUTHORS: Aaron Burghardt, Alexander Sack, Andrew Udvare, Bryan Forbes, Chow Loong Jin,
Christophe Fergeau, Dogbert, Elan Ruusamäe, Filippo Bigarella, Frederik Carlier, Glenn
Washburn, Greg Dennis, Ingmar Vanhassel, Jim Koning, Jonathan Beck, Julien Blache, Martin
Aumueller, Martin Szulecki, Matt Colyer, Matthias Klose, Nicolás Alvarez, Nikias Bassen,
Patrick von Reth, Patrick Walton, Paul Sladen, Shane G, Wang Junjie, Zach C.

### libimobiledevice-glue

```
Copyright (c) 2013      Federico Mena Quintero
Copyright (c) 2009      Hector Martin <hector@marcansoft.com>
Copyright (c) 2012-2014 Martin Szulecki <m.szulecki@libimobiledevice.org>
Copyright (c) 2009-2024 Nikias Bassen <nikias@gmx.li>
```

### libtatsu

```
Copyright (c) 2010      Joshua Hill
Copyright (c) 2010-2013 Martin Szulecki
Copyright (c) 2012-2024 Nikias Bassen
```

### libirecovery

```
Copyright (c) 2010-2011 Chronic-Dev Team
Copyright (c) 2010-2011 Joshua Hill
Copyright (c) 2012-2020 Martin Szulecki <martin.szulecki@libimobiledevice.org>
Copyright (c) 2008-2011 Nicolas Haunold
Copyright (c) 2011-2023 Nikias Bassen <nikias@gmx.li>
```

### libusbmuxd

```
Copyright (c) 2017      Adrien Guinet <adrien@guinet.me>
Copyright (c) 2009      Hector Martin <hector@marcansoft.com>
Copyright (c) 2008      Jing Su
Copyright (c) 2009-2014 Martin Szulecki <m.szulecki@libimobiledevice.org>
Copyright (c) 2009-2020 Nikias Bassen <nikias@gmx.li>
Copyright (c) 2009      Paul Sladen <libiphone@paul.sladen.org>
```

AUTHORS: Aaron Burghardt, Bastien Nocera, Cerrato Renaud, Chow Loong Jin, David Sansome,
Eric Day, Hector Martin, Martin Szulecki, Nikias Bassen, Paul Sladen.

### libimobiledevice

```
Copyright (c) 2014      Aaron Burghardt
Copyright (c) 2014      BALATON Zoltan
Copyright (c) 2010      Bryan Forbes
Copyright (c) 2014      Christophe Fergeau
Copyright (c) 2021      Geoffrey Kruse
Copyright (c) 2014      Google Inc.
Copyright (c) 2008-2009 Jonathan Beck
Copyright (c) 2010      Joshua Hill
Copyright (c) 2014      Koby Boyango
Copyright (c) 2009-2015 Martin Szulecki
Copyright (c) 2022      Matthias Ringwald
Copyright (c) 2009-2025 Nikias Bassen <nikias@gmx.li>
Copyright (c) 2015      Reyk Floter <reyk@openbsd.org>
Copyright (c) 2013      Yury Melnichek
Copyright (c) 2008      Zach C.
```

AUTHORS: Bastien Nocera, Bryan Forbes, Christophe Fergeau, Geoff Paul, Ingmar Vanhassel,
John Maguire, Jonathan Beck, Joshua Hill, Julien Lavergne, Martin Aumueller, Martin
Szulecki, Marty Rosenberg, Matt Colyer, Nikias Bassen, Patrick Walton, Paul Sladen, Peter
Hoepfner, Petr Uzel, Todd Zullinger, Zach C, Zoltan Balaton.

### usbmuxd

```
Copyright (c) 2013      Federico Mena Quintero
Copyright (c) 2009      Hector Martin "marcan" <hector@marcansoft.com>
Copyright (c) 2009-2020 Martin Szulecki <martin.szulecki@libimobiledevice.org>
Copyright (c) 2014      Mikkel Kamstrup Erlandsen <mikkel.kamstrup@xamarin.com>
Copyright (c) 2009-2021 Nikias Bassen <nikias@gmx.li>
Copyright (c) 2009      Paul Sladen <libiphone@paul.sladen.org>
```

Licence statement from the source headers: "This program is free software; you can
redistribute it and/or modify it under the terms of the GNU General Public License as
published by the Free Software Foundation, either version 2 or version 3." Both texts
(`COPYING.GPLv2`, `COPYING.GPLv3`) ship in the tree.

AUTHORS: Aaron Burghardt, Bastien Nocera, Cerrato Renaud, Christophe Fergeau, David
Sansome, Hector Martin, Jacob Myers, John Maguire, Martin Szulecki, Mikkel Kamstrup
Erlandsen, Nikias Bassen, Paul Sladen, Peter Wu, Satoshi Ohgoh.

### idevicerestore

```
Copyright (c) 2014      BALATON Zoltan
Copyright (c) 2010      Chronic-Dev Team
Copyright (c) 2010      Joshua Hill
Copyright (c) 2010-2015 Martin Szulecki
Copyright (c) 2012-2024 Nikias Bassen
Copyright (c) 2025      Visual Ehrmanntraut <visual@chefkiss.dev>
```

AUTHORS: Joshua Hill, Martin Szulecki, Nikias Bassen.

The t1-revive patch adds `src/t1.c` and `src/t1.h` — Apple T1 / iBridge1,1 (x619ap)
EmbeddedOS restore support: firmware-bundle compatibility by ApChipID/ApBoardID, a restore
with no OS filesystem, the EmbeddedOS `StartRestore` options, FDR memory-store
capture/acknowledge/replay, preflight capture of the combined memboot image and its AP
ticket, and the phase-14 replay — and hooks them into `src/idevicerestore.c`,
`src/restore.c` and `src/Makefile.am`. Every hook is inert unless an `IDEVICERESTORE_T1_*`
environment variable is set.

## Credits

- **The libimobiledevice project** — Nikias Bassen, Martin Szulecki and every contributor
  named above. Everything t1-revive does on the wire is their implementation of Apple's
  protocols; the T1 patches are thin additions on top of it.
- **t1bridge**, by Andrew Boyd (<https://github.com/standardagents/t1bridge>), MIT licensed
  — the userspace stack that drives the Touch Bar and Touch ID once the T1 boots again.
  t1-revive hands the device over to it and bundles none of its code.

## Not included

No Apple software, firmware, keys, tickets or device data is part of this repository or of
any package built from it. Apple's `EmbeddedOSFirmware.pkg` is downloaded from Apple's CDN
at run time, verified against a pinned checksum and cached locally; the result of a restore
is device-specific and never leaves the machine it was made on.
