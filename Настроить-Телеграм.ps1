<#
    Настройка Telegram-уведомлений для WB Монитора
    Версия 1.0.0.0

    Запускается один раз. Спрашивает токен бота, находит chat_id и сохраняет
    их зашифрованными DPAPI — файл читается только из-под текущей учетной
    записи Windows, как токены Jira и Confluence.

    Перед запуском: создать бота в Telegram у @BotFather (/newbot) и получить
    токен вида 1234567890:AAH...

    Запуск:
        powershell -ExecutionPolicy Bypass -File Настроить-Телеграм.ps1
#>

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ФайлНастроек = Join-Path $env:USERPROFILE '.claude\wb_telegram.xml'

function Вызвать-Телеграм {
    param([string]$Токен, [string]$Метод, [hashtable]$Параметры = @{})

    $Адрес = "https://api.telegram.org/bot$Токен/$Метод"
    return Invoke-RestMethod -Uri $Адрес -Method Post -Body $Параметры -TimeoutSec 40
}

function Строка-ИзSecureString {
    param([System.Security.SecureString]$Защищенная)

    $Указатель = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Защищенная)
    try   { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($Указатель) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Указатель) }
}

Write-Host ""
Write-Host "=== Настройка Telegram-уведомлений WB Монитора ==="
Write-Host ""
Write-Host "Если бота еще нет: в Telegram напиши @BotFather, команда /newbot,"
Write-Host "и он выдаст токен вида 1234567890:AAH..."
Write-Host ""

#Область Шаг1_Токен

$Защищенный = Read-Host "Токен бота" -AsSecureString
$Токен = Строка-ИзSecureString -Защищенная $Защищенный

if ([string]::IsNullOrWhiteSpace($Токен)) {
    Write-Host "Токен не введен. Настройка прервана."
    return
}

$Бот = $null
try {
    $Бот = Вызвать-Телеграм -Токен $Токен -Метод "getMe"
} catch {
    Write-Host ""
    Write-Host "Токен не принят: $($_.Exception.Message)"
    Write-Host "Проверь, что скопировал его целиком, вместе с частью до двоеточия."
    return
}

Write-Host ""
Write-Host "Бот найден: @$($Бот.result.username) ($($Бот.result.first_name))"

#КонецОбласти

#Область Шаг2_ЧатИд

Write-Host ""
Write-Host "Теперь открой в Telegram чат с ботом @$($Бот.result.username) и нажми /start."
Write-Host "Если уведомления нужны в группу — добавь туда бота и напиши в ней любое сообщение."
Write-Host ""
Read-Host "Сделал? Нажми Enter"

$Обновления = Вызвать-Телеграм -Токен $Токен -Метод "getUpdates"

$Чаты = @()
foreach ($Обновление in $Обновления.result) {

    $Сообщение = $Обновление.message
    if ($Сообщение -eq $null) { $Сообщение = $Обновление.channel_post }
    if ($Сообщение -eq $null) { continue }

    $Чат = $Сообщение.chat
    if ($Чаты | Where-Object { $_.Ид -eq $Чат.id }) { continue }

    $Название = $Чат.title
    if ([string]::IsNullOrWhiteSpace($Название)) {
        $Название = ("{0} {1} @{2}" -f $Чат.first_name, $Чат.last_name, $Чат.username).Trim()
    }

    $Чаты += [PSCustomObject]@{ Ид = $Чат.id; Название = $Название; Тип = $Чат.type }
}

if ($Чаты.Count -eq 0) {
    Write-Host ""
    Write-Host "Telegram не показал ни одного сообщения боту."
    Write-Host "Причины бывают такие:"
    Write-Host "  - /start еще не отправлен;"
    Write-Host "  - для группы: у бота включен режим приватности, тогда он видит"
    Write-Host "    только команды — напиши в группе /start;"
    Write-Host "  - сообщения уже забрал другой запущенный экземпляр бота."
    Write-Host "Отправь сообщение боту и запусти настройку заново."
    return
}

$Выбранный = $Чаты[0]

if ($Чаты.Count -gt 1) {
    Write-Host ""
    Write-Host "Найдено несколько чатов:"
    for ($i = 0; $i -lt $Чаты.Count; $i++) {
        Write-Host ("  [{0}] {1}  ({2}, id {3})" -f $i, $Чаты[$i].Название, $Чаты[$i].Тип, $Чаты[$i].Ид)
    }
    $Номер = Read-Host "Куда слать уведомления? Номер"
    if ($Номер -match '^\d+$' -and [int]$Номер -lt $Чаты.Count) {
        $Выбранный = $Чаты[[int]$Номер]
    }
}

Write-Host ""
Write-Host "Уведомления будут приходить в: $($Выбранный.Название) (id $($Выбранный.Ид))"

#КонецОбласти

#Область Шаг3_ПроверкаИСохранение

try {
    Вызвать-Телеграм -Токен $Токен -Метод "sendMessage" -Параметры @{
        chat_id = $Выбранный.Ид
        text    = "WB Монитор цен подключен. Сюда будут приходить сообщения об изменении цены."
    } | Out-Null
} catch {
    Write-Host ""
    Write-Host "Не удалось отправить тестовое сообщение: $($_.Exception.Message)"
    Write-Host "Настройки не сохранены."
    return
}

$Папка = Split-Path -Parent $ФайлНастроек
if (-not (Test-Path $Папка)) { New-Item -ItemType Directory -Path $Папка -Force | Out-Null }

[PSCustomObject]@{
    Secret = $Защищенный
    ChatId = [string]$Выбранный.Ид
    Bot    = [string]$Бот.result.username
} | Export-Clixml -Path $ФайлНастроек

Write-Host ""
Write-Host "Готово. Тестовое сообщение отправлено — проверь Telegram."
Write-Host "Настройки сохранены: $ФайлНастроек"
Write-Host "Токен зашифрован DPAPI и читается только под твоей учетной записью Windows."
Write-Host ""
Write-Host "--- Для запуска в GitHub Actions ---"
Write-Host "DPAPI на чужой машине не работает, поэтому там нужны два секрета."
Write-Host "Settings -> Secrets and variables -> Actions -> New repository secret:"
Write-Host ""
Write-Host "  WB_TELEGRAM_TOKEN = токен, который выдал BotFather"
Write-Host "  WB_TELEGRAM_CHAT  = $($Выбранный.Ид)"
Write-Host ""

#КонецОбласти
