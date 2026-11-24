# HayDocs

Приложение для iPhone (в первую очередь iPhone Duo) и iPad: читает PDF, Word (DOCX и DOC), ODT, RTF, TXT, HTML и Markdown с полной поддержкой армянского текста, даёт рисовать поверх страниц Apple Pencil или пальцем, экспортирует и печатает.

## Что умеет

- Библиотека документов: импорт из «Файлов», из других приложений («Поделиться» → HayDocs), из папки HayDocs в «Файлах», фото и сканирование камерой, пустые блокноты (чистые, в линейку, в клетку, в точку).
- Word, ODT, RTF, TXT, HTML и Markdown превращаются в страницы движком [WordCraft](https://github.com/storytold/wordcraft) прямо в телефоне, без интернета.
- Армянский текст:
  - старые документы в кодировке ArmSCII-8 (шрифты «Arial Armenian», «Times Armenian», «ArTarumian…») переводятся в Юникод;
  - если в документе армянский текст набран шрифтом, которого нет в телефоне (GHEA Grapalat, Sylfaen и т. п.), он показывается шрифтом Noto Serif Armenian или Noto Sans Armenian (замену можно выбрать в настройках);
  - свои шрифты .ttf и .otf добавляются в разделе «Шрифты» и сразу используются для документов;
  - в приложении 39 файлов шрифтов с армянскими буквами: Noto Sans/Serif Armenian, Google Sans, Handjet, Tiny5, Iosevka Charon Mono, DejaVu, а также Liberation, Carlito и Caladea с метриками Arial, Times New Roman, Calibri и Cambria.
- Рисование PencilKit поверх каждой страницы, отмена и повтор, ластик, разворот на две страницы на раскрытом iPhone Duo, несколько окон.
- Экспорт: PDF с рисунками, PDF без рисунков, исходный файл, страница картинкой, печать. Поиск по тексту.

## Как собирается

Mac не нужен: GitHub Actions (`.github/workflows/build.yml`) на облачном Mac собирает движок (Rust, `engine/`) для iPhone и симулятора, проект Xcode (`project.yml`, XcodeGen), неподписанный `HayDocs.ipa`, и прогоняет UI-тест на симуляторе iPhone Duo. Готовый `HayDocs.ipa` лежит в пре-релизе `dev`.

## Установка через Sideloadly

1. Подключите iPhone к компьютеру кабелем, откройте Sideloadly.
2. Перетащите `HayDocs.ipa` в окно Sideloadly, введите свой Apple ID, нажмите Start.
3. На iPhone: Настройки → Основные → VPN и управление устройством → ваш Apple ID → «Доверять».
4. Если iPhone попросит, включите Режим разработчика: Настройки → Конфиденциальность и безопасность → Режим разработчика, затем перезагрузка.

С бесплатным Apple ID приложение работает 7 дней, потом его нужно переустановить тем же способом (документы сохраняются).

## Лицензии

Код приложения: MIT. Движок WordCraft: MIT или Apache 2.0. Шрифты: SIL OFL 1.1 и лицензия Bitstream Vera (DejaVu), тексты в `Resources/Fonts/Licenses`.
