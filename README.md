# kqi

Command-line client for NIU KQi kick scooters (built for the KQi Air) over Bluetooth LE,
with the small slice of NIU's cloud API needed to get the scooter's Bluetooth password.
The NIU phone app is the only official way to talk to the scooter; this replaces it for
status, settings, and commands from a Mac.

Nothing here is documented by NIU. The wire protocol, the authentication handshake, the
field table, and the command numbers were recovered from the NIU Android app
(`com.niu.manager` 5.12.2) with jadx. NIU can change any of it in a firmware or app update.
Status: tested end to end against a live KQi Air (2026-09-06). Login, the by-MAC password
fetch, the BLE-20 password handshake, status reads, and settings writes all work. A few
status bits are still unlabeled (see "Known unknowns").

## Install / invoke

macOS only. Python 3.11+ with `bleak` and `cryptography` in a `.venv` next to the code:

```sh
git clone https://github.com/BaesTheorem/niu-kqi && cd niu-kqi
uv venv --python 3.13 .venv && uv pip install --python .venv/bin/python -r requirements.txt
#   or: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
bin/kqi --help
```

`bin/kqi` runs `kqi_ble.py` inside `/Applications/NIU KQi.app`, a tiny bundle it builds on
first use, because macOS only lets Bluetooth through for a responsible app that declares
`NSBluetoothAlwaysUsageDescription` (a bare python process is killed with exit 134 and no
message). The first Bluetooth command prompts once for permission. After moving the checkout,
run any command with `--rebuild` once so the bundle points at the new path.

Linux would need a different launcher (no TCC) but the protocol code is portable.

## One-time setup

```sh
kqi login you@example.com      # NIU account (password prompted, or --password-stdin / $NIU_PASSWORD)

# KQi kick scooter (KQi Air): it is not bound to the cloud. Turn it on, then:
kqi setup --mac auto           # reads its BLE MAC over Bluetooth, fetches the password

# NIU moped, or the kick scooter's MAC known already:
kqi scooters                   # vehicles bound to the account
kqi setup [--sn SN]            # bound vehicle, fetch by serial
kqi setup --mac AA:BB:CC:DD:EE:FF   # kick scooter, MAC given explicitly
```

A kick scooter hands out its Bluetooth password by MAC to any logged-in NIU account
(`v5/device/bluetooth_secret`), so it does not need to be bound. A moped's password comes
from `v5/ble/bleinfo` and does need the vehicle bound to the account.

macOS hides real BLE MACs from a scan, so `kqi mac` (and `setup --mac auto`) get it by
connecting briefly and reading it back from `system_profiler`. The name "NIU Link XXXX"
ends in the last two bytes of the MAC. Credentials land in `secrets/`, gitignored; see
`secrets/README.md`.

## Daily use (scooter on, in range)

```sh
kqi find                       # which advertisement is the scooter; remembers its address
kqi mac                        # print the scooter's real BLE MAC (macOS)
kqi status                     # battery, speed, ride mode, settings bits, firmware, serials
kqi read foc_k_gears bms_soc_rt
kqi write foc_k_max_speed 200  # values in the field's raw unit (speeds are km/h x 10)
kqi lock | unlock              # motor lock (foc_k_cmd 1 / 2)
kqi on | off                   # dashboard power (db_k_cmd 1 / 2)
kqi cruise on|off  kickstart on|off  fastlock on|off  alarm on|off
kqi ebs 0|1|2|3                # regen braking level (bits 256/512 of foc_k_function_status1)
kqi custom on --max 20 | custom off
kqi daylight on|off|led        # daytime running light mode
kqi unit 0|1                   # dashboard speed unit index (0/1; which is mph is confirmed live)
kqi clock                      # writes db_k_timestamp = now
kqi cmd 7 | kqi cmd --db 9     # any foc_k_cmd / db_k_cmd number
kqi monitor --seconds 120      # frames the scooter pushes by itself
kqi raw <hex>                  # send one frame, print replies
kqi fields [--all] [substr]    # the field table
kqi firmware check             # installed firmware version of every controller
kqi firmware pull              # download what NIU will serve (verifies md5) -> firmware/
```

`--json` on `status`/`read`, `-v` to print every frame, `-y` to skip confirmations,
`--address` to skip scanning, `--family 1|2|10` to force a frame family.

## Protocol in one screen

- One GATT service per vehicle: `8ec94e30-f315-4f60-9fb8-838830daea5X`, notify on
  `8ec94e31-...`, write on `8ec94e32-...`. `X` = 0/1/2 means BLE version 10/20/21.
- BLE 10 and 20 speak 20-byte frames: `header(2) index(1) AES-128-ECB(16) checksum(1)`,
  checksum = sum of bytes mod 256, index = frames still to come. Read `0121/0101`, reply
  `01a1/0181`, error `01e1/01c1`; write `0122/0102`, reply `01a2/0182`, error `01e2/01c2`.
  A second header family (`012f/0130`...) exists for older kick scooters.
- BLE 21 speaks `5aa5 len(2) cmd(1) payload cs 96` with every payload byte +51 and no AES;
  read cmd `01` (reply `81`, error `c1`), write `02` (`82`/`c2`).
- Fields are 3-byte codes with fixed type/length (`data/fields.json`: 44 kick-scooter
  `foc_k_*`/`db_k_*` fields and 255 shared `bms_*`/`ecu_*`/`db_*` fields). Reads send codes,
  writes send code+value; replies come back in request order. Unsolicited pushes carry
  code+value pairs.
- Handshake with the 16-char `blePassword`: BLE 10 sends `012301`+AES(random) then
  `010300`+AES(md5(random ‖ reply ‖ password)); BLE 20+ sends `013401`+firstKey
  (AES(rand4 ‖ time+7d ‖ zeros ‖ crc16)) then `011400`+AES(reply[4:8] ‖ rand4 ‖ zeros ‖ crc16),
  and the decrypted first reply is the session key. Data frames use `bleAes` (BLE 10) or the
  session key (BLE 20). CRC-16 is reflected poly 0xA1E8, init 0xFFFF.
- Commands are plain field writes: `foc_k_cmd` (1 lock, 2 unlock, 5/6 kick-start on/off,
  7/8 cruise, 10/11 custom mode, 12/13 speed unit, 18/19 fast lock) and `db_k_cmd`
  (1/2 power on/off, 5/6 alarm sound off/on, 9/10/11 daytime light on/off/follow LED,
  14 security-log ack, 100 factory reset).

## Confirmed on the live KQi Air

- Speeds are km/h times ten: `foc_k_max_speed` 320 = 32.0 km/h, the KQi Air's 20 mph cap.
- The kick scooter is BLE version 20 (service ...`daea51`): AES 20-byte frames, v2 handshake.
- `bms_soc_rt` is battery percent; `db_k_realtime_status` bit 1 is "powered on".
- The by-MAC password fetch needs no binding and no ownership; any logged-in account gets it.

## Firmware

A KQi Air is five controllers, each with its own firmware: motor (`FOC`),
dashboard (`DB`), battery (`BMS`), light unit (`LCU`) and Bluetooth (`ECU_BT`).
The BLE link can read each one's version but cannot dump the image; the image
only lives in NIU's cloud. `kqi firmware check` lists the installed versions;
`kqi firmware pull` fetches what the cloud will serve into `firmware/`.

NIU's `v5/ota/checkupdate` is a version diff, so it only returns a download URL
when you claim a real release older than the newest published one. `pull` reads
the installed versions, walks each down until the server offers an image, and
verifies its md5. On a current KQi Air only the light unit has a published image
(the rest are at factory versions with no OTA update). The image is plain (unencrypted) code whose instruction set is still
unidentified; see `firmware/ANALYSIS.md`.

## Known unknowns

- Bit meanings for the status words live in `BITS` in `kqi_ble.py`; entries marked `(?)`
  are still to be confirmed by toggling them (e.g. which speed-unit index is mph).
- No headlight on/off command was found in the app; only the daytime-light modes.
- If the scooter drops the connection right after connecting (GATT status 19 or 22), the
  app calls it "Need 3 Press key": press the power button three times so it accepts a new
  device, then retry.
- Older kick scooters (product type `ble_kick_scooter`) use the second header family and may
  come without a password; `--family 2` covers that path, untested.

## Files

- `kqi_ble.py` -- CLI and the bleak session (scan, connect, handshake, read/write, pushes).
- `niu_proto.py` -- frames, checksum, CRC, AES, handshake math, field encode/decode. `python niu_proto.py` runs a self-test.
- `niu_cloud.py` -- login (md5 password, oauth2 token), scooter list, detail, `bleinfo`.
- `data/fields.json` -- field table extracted from the app.
- `firmware/` -- controller-firmware fetch (`firmware check`/`pull`), the OTA
  manifest, and the reverse-engineering notes (`ANALYSIS.md`). Images and disasm
  are gitignored (NIU's code); `manifest.example.json` records md5s so a pull verifies.
- `secrets/` -- gitignored credentials.
- `bin/kqi` -- the macOS launcher (builds the app bundle, runs the CLI inside it).
