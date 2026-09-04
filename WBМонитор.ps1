<#
    WB Монитор цен
    Версия 1.5.0.0

    Опрашивает открытый API карточки Wildberries, копит историю цен
    и оповещает, когда цена изменилась или достигла целевой.

    Отслеживается ИТОГОВАЯ сумма — цена товара плюс доставка в твой регион,
    то есть ровно та цифра, которую показывает приложение.

    Уведомления: всплывающее окно Windows и, если настроен, Telegram-бот.
    Настройка бота — один раз через Настроить-Телеграм.ps1. Пока он не настроен,
    Telegram просто пропускается.

    Запуск:
        powershell -ExecutionPolicy Bypass -File WBМонитор.ps1
        powershell -ExecutionPolicy Bypass -File WBМонитор.ps1 -Валюта rub -КодРегиона -1257786
        powershell -ExecutionPolicy Bypass -File WBМонитор.ps1 -БезВсплывающихОкон

    Коды регионов (dest), валюты и разбор итоговой цены — см. README.md
#>

param(
    [switch]$БезВсплывающихОкон,
    [ValidateSet("kzt", "rub", "byn", "uzs", "kgs", "amd", "usd")]
    [string]$Валюта = "kzt",
    [int]$КодРегиона = 269,               # 269 = Актобе; 234 = Алматы; -1257786 = Москва
    [bool]$УчитыватьДоставку = $true,     # как в приложении: цена + доставка
    [double]$СкидкаКошелькаПроцент = 0    # если WB Кошелек дает скидку на товар, %
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

#Область Пути

$ПутьСкрипта  = $PSScriptRoot
$ФайлТоваров  = Join-Path $ПутьСкрипта "Товары.txt"
$ФайлИстории  = Join-Path $ПутьСкрипта "История.csv"
$ФайлЛога     = Join-Path $ПутьСкрипта "Оповещения.log"
$ФайлПроверки = Join-Path $ПутьСкрипта "ПоследняяПроверка.txt"

# локально настройки Telegram лежат рядом с токенами Jira и Confluence, зашифрованные DPAPI.
# В GitHub Actions DPAPI недоступен, поэтому там токен берется из переменных окружения.
$ФайлТелеграм = Join-Path $HOME '.claude/wb_telegram.xml'

# $IsWindows есть только в PowerShell 7; в 5.1 переменной нет и она молча равна $null
$ЭтоWindows = $true
if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) { $ЭтоWindows = $IsWindows }

$Единицы = @{
    "kzt" = "тг"; "rub" = "руб"; "byn" = "BYN"; "uzs" = "сум"
    "kgs" = "сом"; "amd" = "драм"; "usd" = "USD"
}
$Единица = $Единицы[$Валюта]

#КонецОбласти

#Область СлужебныеФункции

function Записать-Лог {
    param([string]$Текст)

    $Строка = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Текст
    Write-Host $Строка
    Add-Content -Path $ФайлЛога -Value $Строка -Encoding UTF8
}

function Показать-Уведомление {
    param([string]$Заголовок, [string]$Текст)

    if ($БезВсплывающихОкон) { return }
    if (-not $ЭтоWindows) { return }

    $Получилось = $false
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

        $Шаблон = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $Узлы = $Шаблон.GetElementsByTagName("text")
        $Узлы.Item(0).AppendChild($Шаблон.CreateTextNode($Заголовок)) | Out-Null
        $Узлы.Item(1).AppendChild($Шаблон.CreateTextNode($Текст)) | Out-Null

        $ИдПриложения = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"
        $Уведомление = New-Object Windows.UI.Notifications.ToastNotification $Шаблон
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ИдПриложения).Show($Уведомление)
        $Получилось = $true
    } catch {
        $Получилось = $false
    }

    # MessageBox ждет нажатия кнопки, поэтому в фоновом сеансе его показывать нельзя —
    # иначе прогон повиснет до таймаута
    if (-not $Получилось -and [Environment]::UserInteractive) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show($Текст, $Заголовок) | Out-Null
            $Получилось = $true
        } catch {
            $Получилось = $false
        }
    }

    if (-not $Получилось) { Write-Host "!!! $Заголовок : $Текст" }
}

function Прочитать-НастройкиТелеграм {

    # приоритет у переменных окружения: так работает GitHub Actions и любой сервер
    if (-not [string]::IsNullOrWhiteSpace($env:WB_TELEGRAM_TOKEN) -and
        -not [string]::IsNullOrWhiteSpace($env:WB_TELEGRAM_CHAT)) {
        return @{ Токен = $env:WB_TELEGRAM_TOKEN; ЧатИд = $env:WB_TELEGRAM_CHAT }
    }

    if (-not (Test-Path $ФайлТелеграм)) { return $null }

    try {
        $Настройки = Import-Clixml -Path $ФайлТелеграм
        $Указатель = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Настройки.Secret)
        try   { $Токен = [Runtime.InteropServices.Marshal]::PtrToStringAuto($Указатель) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Указатель) }

        return @{ Токен = $Токен; ЧатИд = $Настройки.ChatId }
    } catch {
        Записать-Лог "Не удалось прочитать настройки Telegram: $($_.Exception.Message)"
        return $null
    }
}

function Отправить-Телеграм {
    param([string]$Текст)

    $Настройки = Прочитать-НастройкиТелеграм
    if ($Настройки -eq $null) { return }

    try {
        Invoke-RestMethod -Uri "https://api.telegram.org/bot$($Настройки.Токен)/sendMessage" -Method Post -TimeoutSec 40 -Body @{
            chat_id                  = $Настройки.ЧатИд
            text                     = $Текст
            disable_web_page_preview = "true"
        } | Out-Null
        Записать-Лог "Отправлено в Telegram"
    } catch {
        Записать-Лог "Не удалось отправить в Telegram: $($_.Exception.Message)"
    }
}

function Ссылка-НаТовар {
    param([string]$Артикул)

    return "https://www.wildberries.ru/catalog/$Артикул/detail.aspx"
}

function Вычислить-Итого {
    param($Данные)

    $Товар = $Данные.Цена
    if ($СкидкаКошелькаПроцент -gt 0) {
        $Товар = [Math]::Round($Товар * (1 - $СкидкаКошелькаПроцент / 100), 0)
    }

    $Доставка = 0
    if ($УчитыватьДоставку) { $Доставка = $Данные.Доставка }

    return $Товар + $Доставка
}

function Прочитать-СписокТоваров {

    $Список = @()

    if (-not (Test-Path $ФайлТоваров)) {
        Записать-Лог "Не найден файл со списком товаров: $ФайлТоваров"
        return $Список
    }

    foreach ($Строка in (Get-Content -Path $ФайлТоваров -Encoding UTF8)) {

        $Строка = $Строка.Trim()
        if ($Строка -eq "")          { continue }
        if ($Строка.StartsWith("#")) { continue }

        $Части   = $Строка.Split(";")
        $Артикул = $Части[0].Trim()
        if ($Артикул -notmatch '^\d+$') { continue }

        $ЦелеваяЦена = 0
        if ($Части.Count -gt 1) {
            $Значение = $Части[1].Trim() -replace '[^\d]', ''
            if ($Значение -ne "") { $ЦелеваяЦена = [decimal]$Значение }
        }

        $Заметка = ""
        if ($Части.Count -gt 2) { $Заметка = $Части[2].Trim() }

        $Список += [PSCustomObject]@{
            Артикул     = $Артикул
            ЦелеваяЦена = $ЦелеваяЦена
            Заметка     = $Заметка
        }
    }

    return $Список
}

function Получить-ДанныеWB {
    param([string[]]$Артикулы)

    $Результат = @{}

    $Заголовки = @{
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        "Accept"     = "*/*"
    }

    $РазмерПорции = 50
    for ($Начало = 0; $Начало -lt $Артикулы.Count; $Начало += $РазмерПорции) {

        $Порция = $Артикулы[$Начало..([Math]::Min($Начало + $РазмерПорции - 1, $Артикулы.Count - 1))]
        $Адрес  = "https://card.wb.ru/cards/v4/detail?appType=1&curr=$Валюта&dest=$КодРегиона&spp=30&ab_testing=false&lang=ru&nm=" + ($Порция -join ";")

        # при 429 (слишком часто) ждем и пробуем еще раз, пауза растет: 5, 15, 45 секунд
        $Ответ = $null
        $Пауза = 5
        foreach ($Попытка in 1..4) {

            try {
                $Ответ = Invoke-WebRequest -Uri $Адрес -Headers $Заголовки -TimeoutSec 40 -UseBasicParsing
                break
            } catch {
                $Ответ = $null

                $Код = 0
                if ($_.Exception.Response -ne $null) { $Код = [int]$_.Exception.Response.StatusCode }

                if ($Попытка -eq 4 -or ($Код -ne 429 -and $Код -ne 0)) {
                    Записать-Лог "Ошибка запроса к WB (код $Код): $($_.Exception.Message)"
                    break
                }

                Записать-Лог "WB ответил $Код, повтор через $Пауза с (попытка $Попытка из 4)"
                Start-Sleep -Seconds $Пауза
                $Пауза = $Пауза * 3
            }
        }

        if ($Ответ -eq $null) { continue }

        # PowerShell 5.1 отдает Content уже испорченным однобайтовой кодировкой,
        # поэтому читаем сырой поток. В PowerShell 7 потока может не быть — там Content уже строка.
        $Текст = $null
        if ($Ответ.RawContentStream -ne $null) {
            try { $Текст = [System.Text.Encoding]::UTF8.GetString($Ответ.RawContentStream.ToArray()) } catch { $Текст = $null }
        }
        if ([string]::IsNullOrWhiteSpace($Текст)) { $Текст = $Ответ.Content }
        $Данные = $Текст | ConvertFrom-Json

        foreach ($Товар in $Данные.products) {

            $Размер = $Товар.sizes | Where-Object { $_.price -ne $null -and $_.price.product -gt 0 } | Select-Object -First 1

            $Цена        = 0
            $ЦенаБазовая = 0
            $Доставка    = 0
            if ($Размер -ne $null) {
                $Цена        = [Math]::Round($Размер.price.product   / 100, 2)
                $ЦенаБазовая = [Math]::Round($Размер.price.basic     / 100, 2)
                $Доставка    = [Math]::Round($Размер.price.logistics / 100, 2)
            }

            $Результат[[string]$Товар.id] = [PSCustomObject]@{
                Артикул      = [string]$Товар.id
                Наименование = ("{0} {1}" -f $Товар.brand, $Товар.name).Trim()
                Цена         = $Цена
                ЦенаБазовая  = $ЦенаБазовая
                Доставка     = $Доставка
                Остаток      = [int]$Товар.totalQuantity
            }
        }
    }

    return $Результат
}

function Прочитать-Историю {

    $Итог = @{}
    if (-not (Test-Path $ФайлИстории)) { return $Итог }

    foreach ($Строка in (Import-Csv -Path $ФайлИстории -Delimiter ";" -Encoding UTF8)) {
        if ($Строка.Валюта -ne $Валюта) { continue }   # цены в другой валюте не сравниваем
        $Итог[$Строка.Артикул] = $Строка
    }

    return $Итог
}

function Число-ИзИстории {
    param([string]$Значение)

    if ([string]::IsNullOrWhiteSpace($Значение)) { return [decimal]0 }
    return [decimal]($Значение -replace ',', '.')
}

function Новая-ЗаписьИстории {
    param($Данные, [decimal]$Итого, [string]$Момент)

    $Инвариант = [System.Globalization.CultureInfo]::InvariantCulture

    return [PSCustomObject]@{
        Дата         = $Момент
        Артикул      = $Данные.Артикул
        Наименование = $Данные.Наименование
        Валюта       = $Валюта
        Итого        = $Итого.ToString($Инвариант)
        Цена         = $Данные.Цена.ToString($Инвариант)
        Доставка     = $Данные.Доставка.ToString($Инвариант)
        ЦенаБазовая  = $Данные.ЦенаБазовая.ToString($Инвариант)
        Остаток      = $Данные.Остаток
    }
}

function Дописать-Историю {
    param($Записи)

    if ($Записи.Count -eq 0) { return }

    $Записи |
        Select-Object Дата, Артикул, Наименование, Валюта, Итого, Цена, Доставка, ЦенаБазовая, Остаток |
        Export-Csv -Path $ФайлИстории -Delimiter ";" -Encoding UTF8 -NoTypeInformation -Append
}

#КонецОбласти

#Область ОсновнойАлгоритм

$Товары = Прочитать-СписокТоваров
if ($Товары.Count -eq 0) {
    Записать-Лог "Список товаров пуст — заполните Товары.txt"
    return
}

$Данные = Получить-ДанныеWB -Артикулы ($Товары | ForEach-Object { $_.Артикул })
if ($Данные.Count -eq 0) {
    Записать-Лог "WB не вернул ни одного товара"
    return
}

$Предыдущие  = Прочитать-Историю
$НовыеЗаписи = @()
$Падения     = @()
$Подорожания = @()
$Момент      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

foreach ($Товар in $Товары) {

    $Текущее = $Данные[$Товар.Артикул]

    if ($Текущее -eq $null) {
        Записать-Лог "Артикул $($Товар.Артикул) не найден на WB"
        continue
    }

    if ($Текущее.Цена -le 0) {
        Записать-Лог "$($Товар.Артикул) — нет в наличии: $($Текущее.Наименование)"
        continue
    }

    $Итого = Вычислить-Итого -Данные $Текущее

    $Расшифровка = ""
    if ($УчитыватьДоставку) {
        $Расшифровка = "({0:N0} + {1:N0} дост.)" -f $Текущее.Цена, $Текущее.Доставка
    }

    Write-Host ("{0,-12} {1,10:N0} {2,-4} {3,-26} ост. {4,-5} {5}" -f `
        $Текущее.Артикул, $Итого, $Единица, $Расшифровка, $Текущее.Остаток, $Текущее.Наименование)

    $Предыдущая = $Предыдущие[$Товар.Артикул]

    if ($Предыдущая -eq $null) {
        Записать-Лог "Первое наблюдение: $($Текущее.Наименование) — $Итого $Единица"
        $НовыеЗаписи += Новая-ЗаписьИстории -Данные $Текущее -Итого $Итого -Момент $Момент
        continue
    }

    $ИтогоПрошлое = Число-ИзИстории -Значение $Предыдущая.Итого
    $ЦенаПрошлая  = Число-ИзИстории -Значение $Предыдущая.Цена
    $Дельта       = $Итого - $ИтогоПрошлое

    if ($Дельта -eq 0) { continue }

    $НовыеЗаписи += Новая-ЗаписьИстории -Данные $Текущее -Итого $Итого -Момент $Момент

    # отдельно помечаем случай, когда сам товар не дешевел, а изменилась только доставка
    $ЧтоИзменилось = "цена товара"
    if ($Текущее.Цена -eq $ЦенаПрошлая) { $ЧтоИзменилось = "только доставка" }

    $Знак    = "-"
    $Значок  = [char]::ConvertFromUtf32(0x1F4C9)   # график вниз
    $Глагол  = "ПОДЕШЕВЕЛ"
    if ($Дельта -gt 0) {
        $Знак   = "+"
        $Значок = [char]::ConvertFromUtf32(0x1F4C8)   # график вверх
        $Глагол = "ПОДОРОЖАЛ"
    }

    $Процент = [Math]::Round([Math]::Abs($Дельта) / $ИтогоПрошлое * 100, 1)

    $Сообщение = "{0} {1}`n{2:N0} -> {3:N0} {4}  ({5}{6:N0}, {5}{7}%)`nизменилась {8}" -f `
        $Значок, $Текущее.Наименование, $ИтогоПрошлое, $Итого, $Единица, `
        $Знак, [Math]::Abs($Дельта), $Процент, $ЧтоИзменилось

    Записать-Лог "$Глагол : $($Текущее.Наименование) — было $ИтогоПрошлое, стало $Итого $Единица ($Знак$([Math]::Round([Math]::Abs($Дельта))), $Знак$Процент%, изменилась $ЧтоИзменилось)"

    if ($Товар.ЦелеваяЦена -gt 0 -and $Итого -le $Товар.ЦелеваяЦена) {
        $Сообщение = $Сообщение + ("`n{0} цель {1:N0} достигнута" -f [char]::ConvertFromUtf32(0x1F3AF), $Товар.ЦелеваяЦена)
        Записать-Лог "ДОСТИГНУТА ЦЕЛЕВАЯ ЦЕНА $($Товар.ЦелеваяЦена) по $($Товар.Артикул)"
    }

    $Сообщение = $Сообщение + "`n" + (Ссылка-НаТовар -Артикул $Текущее.Артикул)

    if ($Дельта -lt 0) { $Падения     += $Сообщение }
    if ($Дельта -gt 0) { $Подорожания += $Сообщение }
}

Дописать-Историю -Записи $НовыеЗаписи

# отметка живости: по ней видно, что монитор отработал, даже когда цены не менялись
Set-Content -Path $ФайлПроверки -Encoding UTF8 -Value ("Последняя проверка: {0} UTC" -f (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss"))

# сначала то, ради чего все затевалось, потом подорожания
$Сообщения = @() + $Падения + $Подорожания

if ($Сообщения.Count -gt 0) {

    $Заголовок = "WB: цены изменились"
    if ($Подорожания.Count -eq 0) { $Заголовок = "WB: цена упала" }
    if ($Падения.Count -eq 0)     { $Заголовок = "WB: цена выросла" }

    Показать-Уведомление -Заголовок $Заголовок -Текст ($Сообщения -join "`n`n")
    Отправить-Телеграм   -Текст ($Сообщения -join "`n`n")
}

#КонецОбласти
