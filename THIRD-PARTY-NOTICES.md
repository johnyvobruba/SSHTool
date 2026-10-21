# Software třetích stran

SSHTool je podepsaný a distribuovaný včetně těchto komponent:

| Komponenta | Licence | Zdroj |
|---|---|---|
| SwiftTerm | MIT | https://github.com/migueldeicaza/SwiftTerm |
| FreeRDP (sdl-freerdp, přibalený v `Contents/Helpers/FreeRDP`) | Apache-2.0 | https://github.com/FreeRDP/FreeRDP |
| Knihovny, na kterých závisí FreeRDP (seznam v `Contents/Resources/FreeRDP-BUNDLED-LIBS.txt`) – např. SDL, OpenSSL, libjpeg-turbo, cJSON, případně FFmpeg | vlastní licence jednotlivých projektů (zlib, Apache-2.0, BSD, LGPL/GPL u FFmpeg podle sestavení) | sestaveno z Homebrew (https://brew.sh), zdrojové kódy u jednotlivých projektů |

Přibalené knihovny jsou nemodifikované binárky z Homebrew. Zdrojové kódy jsou dostupné v repozitářích uvedených projektů;
na vyžádání je autor SSHTool poskytne v rozsahu, který vyžaduje jejich licence.
