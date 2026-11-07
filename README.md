# Keo4 inventura

Nezávislá aplikace pro iPhone a iPad. Načte soubor `Inventura.zip` z programu KEO4, umožní inventuru majetku skenováním kódů a exportuje soubor, který KEO4 načte zpět. Není to oficiální program společnosti ALIS.

## Co umí

- import `Inventura.zip` vytvořeného v KEO4 pro čtečku
- sken QR a čárových kódů kamerou nebo připojenou čtečkou
- označení karty jako nalezené, nenalezené, nebo s návrhem přemístění
- otevření místnosti podle štítku místnosti
- export, který v původním souboru mění jen stav inventarizace

## Sestavení

Xcode 15 nebo novější, cíl iOS 17. Otevřete `Keo.xcodeproj` a spusťte schéma Keo.

Jádro je balíček `KeoCore`. Testy:

```sh
cd KeoCore
swift test
```

## Výměna s KEO4

1. V KEO4 zvolte Akce, Vytvořit soubor pro čtečku. Vznikne `Inventura.zip`.
2. V aplikaci klepněte na Import a soubor vyberte.
3. Po inventuře klepněte na Export.
4. V KEO4 soubor načtěte přes Akce, Nahrát soubor ze čtečky.

Čtečka musí být v režimu Bluetooth HID, tedy se chovat jako klávesnice. Telefon nechte v češtině. Režimy SPP a BLE aplikace nepoužívá.

Vzorová inventura a snímky obrazovky jsou ve složce `Vzor`.

© 2026 Samek Tomáš
