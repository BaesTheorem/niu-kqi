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

## Architecture: unconfirmed. M-CORE family is the leading candidate

The image is definitely plain code, not encrypted, but the exact ISA is **not
established**. An earlier version of this file claimed M-CORE was confirmed; a
control run disproved the evidence for that, so here is the honest state.

**What is solid:**

1. **It is not any common architecture.** A capstone linear sweep under ARM,
   Thumb, ARM64, MIPS, PPC, SPARC, RISC-V, SuperH, XCore, SystemZ and
   TMS320C64x all collapse under ~1.1% coverage. A 35 KB ARM image would carry
   hundreds of `push {lr}` / `bx lr`; this has 7 and 1.

2. **It is not encrypted or compressed.** Entropy is 6.38 bits/byte, and the
   image contains large runs of zero padding (1939 words decode as `bkpt`,
   i.e. `0x0000`). Encrypted or packed data sits at ~7.99. For contrast, the
   KQi3 `FOC` images circulated by the ScooterHacking community measure 7.990,
   so NIU *does* encrypt at least some controller images. This LCU image is
   not one of them.

**What does NOT hold up.** The branch-target test previously cited here is
worthless on its own. mcore is a dense 16-bit ISA whose branches are short and
PC-relative, so targets land near the PC no matter what the bytes are:

| sample                          | entropy | in-range branch targets |
|---------------------------------|---------|-------------------------|
| this LCU image                  | 6.38    | 99.8%                   |
| KQi3 FOC image (encrypted)      | 7.99    | 96.6%                   |
| **pure random bytes (control)** | 8.00    | **96.3%**               |

Random noise scores 96.3%, so 99.8% is a few points above chance, not proof.
The same caveat applies to the instruction census: under a dense decoder,
arbitrary bytes also yield a plausible-looking mix of `movi`/`ld.w`/`st.b`. The
one census difference that does survive is this image's much higher call
density (`bsr`) and its zero padding, both of which say "real code" without
saying *which* ISA.

**Where that leaves it.** A 16-bit big-endian core in the M-CORE/C-SKY family
remains the best guess: the encoding width fits, the `0xC0000000` code base
fits, and C-SKY is ubiquitous in Chinese MCUs. But mcore, arc and xtensa are
all dense decoders that swallow arbitrary bytes, and nothing here separates
them convincingly. Treat `KAB2FV20.asm` as a working hypothesis, not a
faithful listing.

**To actually settle it:** disassemble with a real C-SKY binutils
(`csky-abiv2-elf-objdump -b binary -m csky -EB -D`) and check whether function
prologues/epilogues pair up and whether call targets land on function starts.
That structural coherence, not raw branch range, is the test that discriminates.

## Reproduce

```sh
bin/kqi firmware check           # installed versions of all five controllers
bin/kqi firmware pull            # download what NIU will serve (LCU), verify md5
cd firmware && ./disasm.sh KAB2FV20.bin   # regenerate the .asm
```
