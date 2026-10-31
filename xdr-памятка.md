# XDR-яркость на MacBook Pro M5 Pro — памятка

Машина: MacBook Pro Mac17,8, M5 Pro, 48 ГБ, macOS 27.0 beta.
Дисплей: встроенный XDR, 3456×2234, реальный пик 1600 нит.

## СИМПТОМ
Экран темнеет при Cmd+Tab и при заходе в Mission Control.

## ПРИЧИНА
Яркость выше 100 % даётся программным слоем поверх картинки
(Metal-оверлей в BetterDisplay 4.x, фильтр композитора в 5.x).
При переключении окон WindowServer перестраивает сцену, слой теряется,
яркость падает до обычной. Лечится уходом на прямое управление панелью.

## ЛЕЧЕНИЕ — порядок важен

1. Поставить BetterDisplay ветки 5.0.x (пререлиз под macOS 27).
   Стабильная 4.3.x отстаёт от беты ОС. github.com/waydabber/BetterDisplay/releases

2. Settings → Displays → Color LCD →
   включить «Разрешить прямое управление и масштабирование XDR» (Экспериментально).

3. Там же → «Дополнительные настройки яркости Apple…»:
   - Минимум прямой шкалы яркости = 0
   - Максимум прямой шкалы яркости = 1600
   - «Принудительно включить режим EDR» = включено
   Минимум и максимум НЕ должны совпадать. Если min = max, регулировка мертва,
   яркость прибита к пику и клавишами не убавляется.

4. Иконка в строке меню → кнопка «…» внизу справа (секция «Переключатели»
   спрятана за ней) → под дисплеем Color LCD:
   - выключить «Масштабирование яркости»
   - включить «Масштабирование яркости (прямое)»
   Именно в таком порядке — иначе включить не даст.

5. Проверка: ползунок яркости должен подписаться
   «Яркость (прямое масштабирование XDR)».

ГЛАВНОЕ: разрешить в настройках ≠ включить. Настройки только открывают функцию,
активация живёт исключительно в меню строки меню.

Нужен Универсальный доступ для BetterDisplay: прямой режим несовместим со штатной
регулировкой macOS, клавиши F1/F2 должен перехватывать он, иначе они драться будут.

## ПРОВЕРИТЬ СОСТОЯНИЕ ОДНОЙ КОМАНДОЙ

    defaults read pro.betterdisplay.BetterDisplay | grep -iE "enableAppleBuiltInDirect|DirectMin|DirectMax|ForceEDR"

Должно быть:

    enableAppleBuiltInDirectControl = 1
    appleBuiltInDirectMinBrightness = 0
    appleBuiltInDirectMaxBrightness = 1600
    appleBuiltInDirectForceEDR      = 1

Если enable... = 0, а allow... = 1 — значит забыт шаг 4.

## ОТКАТ
Выключить «Масштабирование яркости (прямое)», включить обычное
«Масштабирование яркости». Ничего необратимого.

## РЕШЕНО (31.10.2026): как BetterDisplay делает «прямое» XDR — и Lumen так же

Разобрано по бинарнику BetterDisplay 5.2.1 (класс AppleBuiltInDirectController) и проверено
на живой панели. Никакого слоя поверх картинки, никаких прав администратора:

1. Яркость пишется в нитах прямо во фреймбуфер встроенного экрана:
       IORegistryEntrySetCFProperty(IOMobileFramebufferShim, "IOMFBBrightnessLevel", nits × 65536)
   Фреймбуфер встроенного — тот, у кого есть свойство BLNitsCap. Диапазон 2…1600 нит
   (ccMinNitsConfig = 2, IOMFBIndicatorNitsCap = 1600).
2. Экран переводится на пресет без HDR «Apple Display (P3-600 nits)». На пресете XDR P3-1600
   WindowServer сам держит подсветку на «600 × текущий EDR headroom» и перетирает запись.
   ВОТ ПОЧЕМУ BetterDisplay при запуске ставит P3-600 — это не баг, а условие работы.
3. На P3-600 система опускает потолок BLNitsCap до 600 и драйвер режет всё, что выше.
   Потолок тоже пишется: "BLNitsCap" = 1600 × 65536.
4. Автояркость выключается: DisplayServicesEnableAmbientLightCompensation(id, false).
5. После смены пресета, сна, пробуждения система ~2 с плавно ведёт подсветку к своей яркости.
   Помогает: системную яркость поставить на 1.0 (DisplayServicesSetBrightness) и эти секунды
   держать значение каждый кадр.
6. F1/F2 перехватываются (NX_SYSDEFINED, подтип 8, коды 2/3) и съедаются — нужен Универсальный доступ.

Проверено с Lumen на 1100 нит: держится через Mission Control, HDR-слой (edrtest),
системную запись DisplayServicesSetBrightness. При выходе и по kill -TERM возвращается
исходный пресет, автояркость и системная яркость.

Lumen: ~/Developer/Lumen/src, сборка ./build.sh (--install кладёт в /Applications).
BetterDisplay и Lumen одновременно в прямом режиме НЕ запускать — перетягивают подсветку.

Поправка к «Тупикам» ниже: «перешагнуть 600 нит без записи пресета можно только EDR-слоем»
— неверно, см. выше.

## (было нерешённым, объяснено выше) BetterDisplay режет пик панели

BetterDisplay при запуске переводит экран на пресет
«Apple Display (P3-600 nits)» — пик падает с 1600 до 600 нит, EDR не выдаётся вовсе.
Замерено до и после его старта:

    без BetterDisplay: слот 0 «Apple XDR Display (P3-1600 nits)», potential headroom 16
    с BetterDisplay:   слот 1 «Apple Display (P3-600 nits)»,      potential headroom 5

Переключить вручную: Системные настройки → Мониторы → пресет
«Apple XDR Display (P3-1600 nits)». BetterDisplay вернёт своё при следующем запуске.
Если найти, чем это у него отключить — 1600 нит будут без стороннего софта вообще.

## ТУПИКИ — НЕ ПОВТОРЯТЬ

- Vivid на этой машине не работает.
- Нативный XDR-апскейлинг BetterDisplay для этой панели не предлагает —
  следствие того, что панель сидит на пресете P3-600.
- Свой клон Vivid написать НЕЛЬЗЯ: macOS не даёт непривилегированному процессу
  писать пресеты дисплея. SetPresetData возвращает 0, слот остаётся пуст, хотя
  IsPresetWritable = true. Пробовано 5 форм словаря и обе функции записи.
  Потолок SDR задаётся пресетом, поэтому перешагнуть 600 нит без записи пресета
  можно только EDR-слоем поверх картинки — тем самым, что и вызывает затемнение.
- На пресете P3-600 EDR не выдаётся ВООБЩЕ: headroom стоит на 1.0 даже с активным
  HDR-слоем на экране. На XDR-пресете тот же слой вытягивает 2.667 (600 × 2.667 = 1600).

## НАРАБОТКИ

Лежат в ~/Developer/Lumen/probe/. Пересобрать любой:

    env -u SDKROOT xcrun --sdk macosx swiftc -O файл.swift -o имя

    preset    — показать активный пресет / сменить: ./preset 0
    plist     — таблица всех 51 пресета с потолками яркости
    probe2    — чтение приватных API яркости: ./probe2 <символ> <d|f|i|of|od>
    edrtest   — замер EDR headroom с тестовым HDR-слоем
    dis.sh    — дизассемблировать функцию из dyld-кэша: ./dis.sh <символ>

Приватные API, сигнатуры сняты дизассемблированием:

    DisplayServicesSetBrightness(id, Float) -> Int32          // rc=1000 — отказ
    CoreDisplay_Display_GetPotentialHeadroom(id) -> Float
    CoreDisplay_Display_GetUserBrightness(id) -> Double
    CoreDisplay_Display_GetActivePresetIndex(id) -> Int32
    CoreDisplay_Display_SetActivePresetIndex(id, Int32) -> Int32
    CoreDisplay_Display_CopyPresetData(id, Int32) -> CFDictionary
    CoreDisplay_Display_SetPresetData(id, Int32, CFDictionary) -> Int32   // блокируется

RequestHeadroom, IsEDREnabled, GetDisplayBrightnessInNits первым аргументом берут
не id дисплея, а указатель на объект WindowServer — из обычного процесса SIGSEGV.

Ключи пресета, которые решают всё:
PresetMaxSDRLuminance (600) · PresetMaxHDRLuminance (1600) ·
PresetHostMaxSliderBrightness (600) · PresetHostAlwaysRequestMaxHeadroom (0)
