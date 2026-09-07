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

## Architecture: M-CORE family (16-bit, big-endian)

This was the hard part, because it is not ARM. Method and evidence:

1. **Ruled out the usual suspects with capstone.** A linear sweep under ARM,
   Thumb, ARM64, MIPS, PPC, SPARC, RISC-V, SuperH, XCore, SystemZ and
   TMS320C64x all collapsed under ~1.1% coverage. A 35 KB ARM image would have
   hundreds of `push {lr}` / `bx lr`; this has 7 and 1. So it is not any common
   fixed-width RISC.

2. **Tried the exotic cores in radare2** (arc, mcore, nds32, xtensa, nios2,
   tricore). Invalid-instruction rate cleared nds32/nios2/tricore (as noisy on
   the image as on random bytes) but could not separate the dense decoders
   (mcore, arc, xtensa all swallow arbitrary bytes).

3. **Branch-target test settled it.** Disassembled at base `0xC0000000` and
   checked what fraction of branch/call targets land inside the image:

   | arch    | in-range branch targets |
   |---------|-------------------------|
   | mcore   | **99.8%** (1951/1954)   |
   | arc     | 48-62%                  |
   | xtensa  | 63%                     |

   Real code branches to itself; a wrong decoding scatters. 99.8% is decisive.

4. **Instruction census confirms real code.** Under mcore big-endian the whole
   image reads as a sane compiler mix: 1087 `movi`, 923 `bsr` (calls), 825
   `addi`, 730 `ld.w`, 394 `bf`, 345 `st.w`, 286 `jmpi`, 175 `br`, 168 `subi`,
   121 `bt`, 65 `rte`, 55 `jsri`, 37 `jsr`.

M-CORE is Motorola/Freescale's 16-bit big-endian RISC; **C-SKY**, ubiquitous in
Chinese MCUs, is its direct descendant and near-identical at this level. The
`0xC0000000` code base and 16-bit encoding both fit. radare2's `mcore` decoder
is the closest freely available one but not exact: a few pc-relative loads
render impossible operands, which is the tell that the exact core is a C-SKY
variant rather than classic M-CORE.

**To refine:** disassemble with a C-SKY binutils (`csky-abiv2-elf-objdump -b
binary -m csky -EB -D`) or an M-CORE-aware toolchain for a faithful listing. A
true decompiler (Ghidra) would need an M-CORE/C-SKY processor module, which is
not stock.

## Reproduce

```sh
bin/kqi firmware check           # installed versions of all five controllers
bin/kqi firmware pull            # download what NIU will serve (LCU), verify md5
cd firmware && ./disasm.sh KAB2FV20.bin   # regenerate the .asm
```
