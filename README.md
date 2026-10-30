# Mac-Checker

A console tool that checks a used MacBook before you buy it. It installs nothing and changes
nothing: it only reads data from macOS and rates each check as ✔ ok, ▲ warning or ✖ problem.

## Run

Open **Terminal** on the Mac you are about to buy and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Meizuno/Mac-Checker/main/mac-check.sh)
```

Or through a pipe (options go after `-s --`):

```bash
curl -fsSL https://raw.githubusercontent.com/Meizuno/Mac-Checker/main/mac-check.sh | bash -s -- -i
```

Extended check (configuration profiles, firmware password on Intel, SSD wear via `smartctl`):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Meizuno/Mac-Checker/main/mac-check.sh)"
```

### Options

| Option | What it does |
|---|---|
| `-l CODE`, `--lang CODE` | interface language: `en` `uk` `de` `pl` `es` `fr` `it` `pt` `nl` `cs` `tr`; defaults to the system language, falling back to English |
| `-i`, `--interactive` | start the manual tests right away |
| `-n`, `--no-interactive` | don't offer the manual tests |
| `-o FILE`, `--output FILE` | save the report to a text file |
| `--no-color` | plain output without colors |
| `-h`, `--help` | help |
| `-v`, `--version` | version |

Exit code: `0` — no critical problems, `1` — at least one ✖.

## What it checks

**Locks** — Activation Lock / Find My Mac, enrollment in DEP / Apple Business Manager, MDM,
configuration profiles and firmware password (with `sudo`), SIP, FileVault.

**Battery** — charge cycles against the rated lifespan, maximum capacity (from `system_profiler`
and `ioreg`), condition as reported by macOS, signs of a non-genuine replacement, whether the
charger works.

**Storage** — model, size, SMART status; wear and total data written if `smartmontools` is
installed.

**Hardware** — model and serial number, processor, memory, graphics, built-in display, camera,
speakers, microphone, Wi-Fi, Bluetooth.

**Stability** — kernel panics in the logs, thermal throttling, uptime.

**Manual tests** (optional) — keyboard (tracks every key you press), speakers, camera with
microphone (Photo Booth), display for dead pixels (full-screen solid colors).

At the end it prints a checklist of what a script can't verify: the case, liquid damage,
ports, trackpad, Touch ID, and warranty status at checkcoverage.apple.com.

## Limitations

- On recent macOS versions account data is protected by the privacy system, so iCloud sign-in
  is detected only on older versions. Activation Lock is the key indicator.
- Activation Lock status is only available on Macs with a T2 chip or Apple silicon.
- The seller may have cleared the crash logs.
- The script does not replace Apple Diagnostics: start the Mac while holding the power button
  (Apple silicon) or the **D** key (Intel).

Works with the stock `bash 3.2` that ships with macOS and has no third-party dependencies.

## Development

`mac-check.sh` is a generated file — it is kept in the repository as a single file so it can be
run with one `curl` command. Don't edit it directly:

```
src/*.sh        script logic, concatenated in file-name order into main()
lang/*.txt      interface texts, one file per language, in key=text form
build.sh        checks the translations and builds mac-check.sh
check-lang.sh   compares every language with lang/en.txt
```

After changing anything in `src/` or `lang/`, run `./build.sh` and commit the rebuilt
`mac-check.sh` together with your changes. CI runs `./build.sh --check` and fails if the
committed file is out of date.

### Adding a language

1. Copy `lang/en.txt` to `lang/<code>.txt`, where `<code>` is the two-letter macOS language code.
2. Translate the text after each `=`. Keep the keys and every `%s` placeholder; don't use any
   other `%` characters.
3. Run `./build.sh` — it reports missing keys or placeholders and adds the language automatically.

Missing keys fall back to English at runtime.
