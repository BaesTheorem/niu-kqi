# KQi Air firmware notes

Everything here was pulled from NIU's own update cloud and analysed offline. NIU
publishes no firmware and no datasheet; the format and architecture below were
worked out from the image itself and the decompiled Android app.

## What the KQi Air runs

A KQi Air is five separate controllers, each with its own firmware. NIU's
update-check endpoint (`v5/ota/checkupdate`) reports the version installed on
each, keyed by an internal `devicetype`:

| devicetype | controller           | installed version | status field it maps to |
|------------|----------------------|-------------------|-------------------------|
| `FOC`      | Motor Control Unit   | `KAE13G19`        | `foc_s_ver`             |
| `DB`       | Dashboard            | `KAC2FV31`        | `db_sw_ver`             |
| `BMS`      | Battery              | `KCD36V03`        | `bms_s_ver`             |
| `LCU`      | Light Control Unit   | `KAB2FV20`        | (light unit)            |
| `ECU_BT`   | Bluetooth            | `KAC2FV31`        | `ecu_bt_ver`            |

Versions are as read on this unit (serial `KRP0XXXXXXXXXXXX`)

## Getting the image

The BLE link **cannot** read firmware out of the scooter. The wire protocol is
field reads and writes (see the top-level README); there is a version field and
an OTA-progress field, but nothing that streams the image back. The only place a
firmware image lives is NIU's cloud, which pushes it to the scooter over BLE
during an update.

`v5/ota/checkupdate` is a version **diff**, not a download index. You POST the
scooter serial plus a list of `{devicetype, soft_version}` you claim to have;
the server answers with a download `url` + `md5` only when

1. it has a newer published image for that controller than the version you
   claim, **and**
2. the version you claim is a real prior release (a made-up `0.0.0` is ignored).

So to fetch the image actually on the scooter you claim the release just below
it. Claiming `KAB2FV19` yields the current `KAB2FV20`:

```
http://fota.niu.com/download/static/upload/20240530/01b869/KAB2FV20.bin
```

`bin/kqi firmware pull` automates this: it reads the installed versions (an
empty device list makes the server volunteer them all), then walks each version
down until the server hands over a URL, and verifies the md5.

Only the **LCU** has a downloadable image. The other four are at their factory
versions and NIU has never published an OTA update for them, so `checkupdate`
has nothing newer to offer and returns no URL. That is a property of NIU's repo,
not of the tool. Note also that the endpoint throttles: after a burst of checks
it stops offering downloads for a while, so `pull` keeps any image it already
has rather than re-fetching.

## The image: `KAB2FV20.bin` (LCU)

```
size    35176 bytes
md5     66763f8824ba81ffd38b6098039648a7
sha256  7ed86b1e2b545a9b7efc57eff3f9f56742b97f503202dff8702af25744051a46
```

- **Not encrypted.** Entropy is 6.38 bits/byte; AES/compressed output sits at
  ~7.99. The `trans_encryption: 1` flag in the OTA reply refers to the BLE
  transfer being AES-wrapped with the session key (the same handshake the CLI
  already does), not to the file on disk. The file is a plain code image.
- Begins with a short table of 32-bit words in the `0xC00000xx`..`0xC0ffffxx`
  range (a jump/vector table, consistent with code based at `0xC0000000`), then
  16-bit code, then zero padding and a small trailing value.
- No printable strings, which is normal for a bare light-controller image.

## Architecture: unidentified

The image is plain, structured code. Which instruction set it targets is **not
known**, and two earlier guesses recorded here (M-CORE, then C-SKY) did not
survive controls. Documented so nobody repeats the dead ends.

**Established:**

1. **Not encrypted, not compressed.** Entropy 6.38 bits/byte, 256 distinct byte
   values but a spiky histogram: the 16 commonest bytes are 46.4% of the file,
   dominated by `0x00`. Known ARM64 code profiles the same way (59.3%). Encrypted
   or packed data is flat (~7.5% and entropy ~7.99). The file also holds
   internal runs of 64+ zero bytes. It is a flat image with real padding.
2. **Not any architecture GNU binutils knows.** Swept all **419** valid
   `objdump -b binary -m ...` architectures across both endiannesses, scoring
   the invalid-instruction rate. A correct disassembly should sit around 1-5%
   invalid. The *best* score across the entire sweep was ~14%, and most were far
   worse. Nothing fits.
3. **Not ARM/Thumb/ARM64/MIPS/PPC/SPARC/RISC-V/SuperH/XCore/SystemZ/TMS320**
   (capstone linear sweep, all under ~1.1% coverage).

**Why the earlier guesses failed.** Both were artifacts of a missing control.
Structured data decodes "better" than random under *any* decoder, so a gap
against random proves nothing. The control that matters is **structured code of
a known-wrong ISA**. Disassembling known ARM64 code as C-SKY:

| sample                        | invalid as C-SKY LE |
|-------------------------------|---------------------|
| this image                    | 16.4%               |
| **known ARM64 code (control)**| **20.5%**           |
| KQi3 FOC, encrypted           | 28.5%               |
| pure random                   | 28.7%               |

A definitively wrong ISA lands within 4 points of this image, so C-SKY is not
supported. M-CORE is worse than that: this image scores 23.6% under MCore-BE,
*above* both the ARM64 control (18.5%) and random (16.8%). Independently, the
C-SKY disassembly contains **zero call instructions** in 13,496 decoded
instructions and branches to addresses like `0xfffffcc4`. A 35 KB program with
no subroutine calls is not a real program.

Note that `objdump` ignores the C-SKY variant suffix in raw binary mode:
`csky:ck610`, `csky:ck803` and `csky:ck860` produce byte-identical output, and
`csky:bogus` does not error. Any claim about a specific CK core from this route
is meaningless.

**The decisive next step is physical, not analytical:** open the light control
unit and read the part number off the MCU. That is ground truth in five minutes
and beats any amount of further guessing. The remaining analytical
possibilities are a proprietary or uncommon core that binutils does not cover,
or a container/offset structure meaning the code does not start at byte 0.

## Reproduce

```sh
bin/kqi firmware check           # installed versions of all five controllers
bin/kqi firmware pull            # download what NIU will serve (LCU), verify md5
cd firmware && ./disasm.sh KAB2FV20.bin   # regenerate the .asm
```
