# firmware/

KQi Air controller firmware, pulled from NIU's update cloud, plus the analysis.

## What is tracked in git

- `manifest.example.json` - versions, download URL, size and md5 of every controller's
  firmware (facts, not the binary).
- `ANALYSIS.md` - how the image was obtained, its format, and the architecture
  work (it is a 16-bit big-endian M-CORE-family core).
- `disasm.sh` - regenerates a best-effort disassembly from an image.

## What is NOT tracked (gitignored)

- `*.bin` - the firmware images themselves. They are NIU's copyrighted code, so
  they are not redistributed here. Fetch them yourself:

  ```sh
  ../bin/kqi firmware pull
  ```

  `manifest.example.json` records the exact md5 so a pull is verifiable.
- `*.asm` - disassembly derived from those images. Regenerate with
  `./disasm.sh KAB2FV20.bin` (needs `radare2`).

## Quick start

```sh
../bin/kqi firmware check     # list installed versions of all five controllers
../bin/kqi firmware pull      # download whatever NIU will serve, verify md5
./disasm.sh KAB2FV20.bin      # -> KAB2FV20.asm
```

See `ANALYSIS.md` for everything else.
