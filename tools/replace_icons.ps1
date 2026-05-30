# One-shot migration: Material Icons.X (+ _outlined/_rounded/_sharp)
# → AppIcons.X (Lucide-based facade).
#
# IMPORTANT: reads/writes UTF-8 WITHOUT BOM explicitly via .NET API so
# that PowerShell 5.1 на Windows-1251 системе не превращает кириллицу
# в mojibake.
#
# Запускать из корня проекта:
#   pwsh -File tools/replace_icons.ps1

$ErrorActionPreference = 'Stop'

$canonical = @(
    'access_time','schedule','timer','pending_actions','history','history_toggle_off',
    'lock_clock','calendar_today','date_range',
    'account_balance_wallet','account_balance','attach_money','credit_card',
    'currency_exchange','payments','percent','receipt_long','point_of_sale',
    'calculate','shopping_cart','local_shipping',
    'arrow_back','arrow_forward','arrow_upward','arrow_downward','arrow_drop_down',
    'chevron_left','chevron_right','expand_less','expand_more','north_east','south_west',
    'swap_horiz','swap_vert','sort_by_alpha',
    'add_circle_outline','add_business','add_box','add_link','add',
    'remove_circle_outline','remove',
    'delete_forever','delete_outline','delete',
    'edit_note','edit','save','copy',
    'check_circle_outline','check_circle','check','task_alt','fact_check','verified_user',
    'clear_all','clear','close','cancel','block','do_not_disturb','do_disturb_alt',
    'warning_amber','error_outline','info_outline','rocket_launch','star',
    'person_outline','person_add','person_off','person_search',
    'people_outline','people','contacts','manage_accounts',
    'supervisor_account','admin_panel_settings','security','shield','fingerprint',
    'mail_outline','email','phone','call_received','chat_bubble_outline',
    'send','outbox','inbox','notifications_active','notifications_none','notifications',
    'description','notes','note','summarize',
    'file_download','download','upload_file','archive','unarchive',
    'label_outline','flag','place',
    'menu','dashboard','category','grid_view','view_column',
    'filter_alt_off','filter_list','tune','search',
    'visibility_off','visibility','select_all','deselect','touch_app',
    'analytics','insights','query_stats','show_chart','trending_up','pie_chart','bolt',
    'settings','refresh','logout','lock_outline','link_off','cloud_off',
    'language','qr_code','code','power_off',
    'business','desktop_windows','smartphone','devices_other',
    'account_tree','alt_route','fiber_manual_record'
)

$importLine = "import 'package:ethnocount/core/icons/app_icons.dart';"
$utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
$projectRoot = (Resolve-Path .).Path
$libRoot     = Join-Path $projectRoot 'lib'

$files = Get-ChildItem -Path $libRoot -Filter *.dart -Recurse -File
$totalChanged = 0
$totalReplacements = 0

foreach ($file in $files) {
    if ($file.FullName.EndsWith('app_icons.dart')) { continue }

    # Read explicitly as UTF-8 (no BOM detection fallback to system codepage)
    $content  = [System.IO.File]::ReadAllText($file.FullName, $utf8NoBom)
    if ($null -eq $content) { continue }

    $original = $content
    $localReplacements = 0

    foreach ($name in $canonical) {
        $pattern = 'Icons\.' + [regex]::Escape($name) + '(_outlined|_rounded|_sharp)?\b'
        $rx = [regex]$pattern
        $matches = $rx.Matches($content)
        if ($matches.Count -gt 0) {
            $content = $rx.Replace($content, "AppIcons.$name")
            $localReplacements += $matches.Count
        }
    }

    if ($content -ne $original) {
        # Ensure the import is present. Use \r?\n to be line-ending-agnostic
        # and detect file's actual line ending для аккуратной вставки.
        if ($content -notmatch [regex]::Escape($importLine)) {
            $nl = "`n"
            if ($content.Contains("`r`n")) { $nl = "`r`n" }

            # Find the position right after the last `import 'package:...';` line.
            $importRx = [regex]"(?m)^import\s+'[^']+'\s*;\s*\r?\n"
            $allImports = $importRx.Matches($content)
            if ($allImports.Count -gt 0) {
                $last = $allImports[$allImports.Count - 1]
                $insertAt = $last.Index + $last.Length
                $content = $content.Substring(0, $insertAt) + $importLine + $nl + $content.Substring($insertAt)
            } else {
                # No existing import; prepend
                $content = $importLine + $nl + $content
            }
        }

        # Write UTF-8 NO BOM, preserving the file's own newline scheme
        [System.IO.File]::WriteAllText($file.FullName, $content, $utf8NoBom)
        $totalChanged++
        $totalReplacements += $localReplacements
        Write-Host ("OK  {0}: {1} icon replacements" -f $file.Name, $localReplacements)
    }
}

Write-Host ""
Write-Host "Done. Files changed: $totalChanged, total replacements: $totalReplacements"
