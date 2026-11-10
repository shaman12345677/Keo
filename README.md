# Keo4 inventura

Nezávislá aplikace pro inventuru majetku ze souboru `Inventura.zip` z desktopového programu **KEO4**.

**Toto není oficiální software společnosti ALIS.** Není to oficiální verze KEO4 ani oficiální mobilní / desktopová čtečka od ALIS. Vznikla samostatně pro vlastní použití se stejným výměnným souborem inventury.

## Platformy

| Platforma | Jak získat |
| --- | --- |
| iPhone / iPad | App Store — *Keo4 inventura* |
| Mac | App Store — stejná aplikace, čtečka jako HID klávesnice |
| Windows | [GitHub Releases](https://github.com/shaman12345677/Keo/releases) — portable `Keo4 inventura.exe` (bez instalace) |

## Co umí

- import `Inventura.zip` vytvořeného v KEO4 pro čtečku
- sken QR a čárových kódů (kamera na iOS, HID čtečka na Macu a Windows)
- fotografie majetku (iOS/Mac: foťák i album; Windows: z alba / disku)
- označení karty jako nalezené, nenalezené, nebo s návrhem přemístění
- otevření místnosti podle štítku místnosti
- export, který v původním XML mění jen stav inventarizace, oskenování a návrh přemístění

## Windows

1. Stáhněte nejnovější release z [Releases](https://github.com/shaman12345677/Keo/releases).
2. Spusťte `Keo4 inventura.exe` (GitHub může mezeru v názvu souboru nahradit tečkou — po stažení můžete přejmenovat).
3. Otevřete `Inventura.zip`, zapněte skenování a pracujte s čtečkou.

Čtečka zůstává v americkém rozložení klávesnice. Windows může zůstat česky — aplikace bere polohu klávesy, ne znak po českém rozložení.

Po startu aplikace zkontroluje GitHub Releases. Když je novější verze, nabídne otevření stránky ke stažení.

SmartScreen může u nepodepsaného souboru zobrazit varování. Jde o očekávané chování u nepodepsaných portable aplikací.

## Výměna s KEO4

1. V KEO4 zvolte **Akce → Vytvořit soubor pro čtečku**. Vznikne `Inventura.zip`.
2. V aplikaci soubor otevřete (Import / Otevřít).
3. Po inventuře proveďte Export.
4. V KEO4 soubor načtěte přes **Akce → Nahrát soubor ze čtečky**.

Čtečka musí být v režimu Bluetooth HID (chová se jako klávesnice). Režimy SPP a BLE aplikace nepoužívá. Telefon / Mac / Windows nechte v češtině.

## Sestavení ze zdroje

### iOS / Mac

Xcode 15 nebo novější, cíl iOS 17 / macOS 14. Otevřete `Keo.xcodeproj`. Schéma **Keo** je iPhone/iPad, schéma **KeoMac** je Mac.

Jádro je balíček `KeoCore`:

```sh
cd KeoCore
swift test
```

### Windows

Složka `Windows` je Avalonia aplikace (.NET 8):

```sh
export PATH="$HOME/.dotnet:$PATH" DOTNET_ROOT="$HOME/.dotnet"
dotnet test Windows/Keo.Core.Tests/Keo.Core.Tests.csproj
dotnet publish Windows/Keo.App/Keo.App.csproj -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true -o Windows/portable
```

Vzorová inventura a snímky obrazovky jsou ve složce `Vzor`.

© 2026 Samek Tomáš
