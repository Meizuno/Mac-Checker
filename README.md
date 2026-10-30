# mac-check

Консольна утиліта для швидкої перевірки вживаного MacBook перед купівлею.
Нічого не встановлює і не змінює в системі — лише читає дані macOS і видає звіт з оцінкою
✔ / ▲ / ✖.

## Запуск

Відкрийте **Термінал** на Mac, який купуєте, і виконайте:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Meizuno/Mac-Checker/main/mac-check.sh)
```

Або через трубу (параметри передаються після `-s --`):

```bash
curl -fsSL https://raw.githubusercontent.com/Meizuno/Mac-Checker/main/mac-check.sh | bash -s -- -i
```

Розширена перевірка (профілі конфігурації, пароль прошивки на Intel, знос SSD через `smartctl`):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Meizuno/Mac-Checker/main/mac-check.sh)"
```

### Опції

| Опція | Що робить |
|---|---|
| `-l КОД`, `--lang КОД` | мова інтерфейсу: `uk` `en` `de` `pl` `es` `fr` `it` `pt` `nl` `cs` `tr`; типово — мова системи, а якщо її немає в списку — англійська |
| `-i`, `--interactive` | одразу запустити ручні тести |
| `-n`, `--no-interactive` | не пропонувати ручні тести |
| `-o ФАЙЛ`, `--output ФАЙЛ` | зберегти звіт у текстовий файл |
| `--no-color` | вивід без кольорів |
| `-h`, `--help` | довідка |

Код виходу: `0` — критичних проблем немає, `1` — є хоча б одна ✖.

## Що перевіряється

**Блокування** — Activation Lock / «Знайти Mac», реєстрація в DEP/Apple Business Manager, MDM,
профілі конфігурації та пароль прошивки (з `sudo`), SIP, FileVault.

**Батарея** — кількість циклів відносно ресурсу, максимальна ємність (з `system_profiler` та `ioreg`),
стан за оцінкою macOS, ознаки неоригінальної заміни, робота зарядного пристрою.

**Накопичувач** — модель, обсяг, SMART-статус; знос і обсяг записаних даних, якщо встановлено
`smartmontools`.

**Залізо** — модель і серійний номер, процесор, пам'ять, графіка, вбудований дисплей, камера,
динаміки, мікрофон, Wi-Fi, Bluetooth.

**Стабільність** — kernel panic у журналах, тротлінг через перегрів, час роботи.

**Ручні тести** (за бажанням) — клавіатура (відстежує кожну натиснуту клавішу), динаміки,
камера з мікрофоном (Photo Booth), екран на биті пікселі (однотонні кольори на весь екран).

Наприкінці — чекліст того, що скрипт перевірити не може: корпус, сліди рідини, порти,
трекпад, Touch ID, гарантія на checkcoverage.apple.com.

## Обмеження

- У нових macOS дані акаунтів закриті системою захисту приватності, тож вхід в iCloud
  перевіряється лише на старих версіях. Головний індикатор — Activation Lock.
- Activation Lock видно лише на Mac з чипом T2 або Apple Silicon.
- Журнали збоїв продавець міг очистити.
- Скрипт не замінює Apple Diagnostics: увімкніть Mac, утримуючи кнопку живлення
  (Apple Silicon) або клавішу **D** (Intel).

Сумісний зі штатним `bash 3.2` у macOS, без сторонніх залежностей.

## Як додати мову

Усі тексти зібрані в каталогах `catalog_<код>` наприкінці `mac-check.sh` у форматі `ключ=текст`
(`%s` — місце для значення). Скопіюйте `catalog_en` як `catalog_<код>`, перекладіть тексти і
допишіть код у змінну `LANGS` на початку файлу. Якщо якогось ключа бракує, буде показано англійський текст.

## English

A console tool that checks a used MacBook before you buy it: Activation Lock, MDM/DEP enrollment,
battery cycles and capacity, SSD SMART status, built-in hardware, kernel panics, plus optional
manual tests for the keyboard, speakers, camera and display. It only reads system data and changes
nothing.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Meizuno/Mac-Checker/main/mac-check.sh) --lang en
```

The interface language follows the system language. Available: English, Ukrainian, German,
Polish, Spanish, French, Italian, Portuguese, Dutch, Czech and Turkish (`-l en|uk|de|pl|es|fr|it|pt|nl|cs|tr`);
anything else falls back to English. Run `--help` for all options. To add a language, copy
`catalog_en` at the end of the script to `catalog_<code>`, translate it and add the code to `LANGS`.
