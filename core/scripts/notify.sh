#!/bin/bash
# core/scripts/notify.sh
# Cross-platform notifications (macOS, Linux, WSL)
#
# Usage: notify.sh [TITLE] [MESSAGE]

TITLE="${1:-HYPE}"
MSG="${2:-Уведомление}"

# Detect platform
is_wsl() {
    grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null
}

is_macos() {
    [[ "$OSTYPE" == "darwin"* ]]
}

# Send notification based on platform
notify_sent=false

if is_macos; then
    # macOS: osascript
    if osascript -e "display notification \"$MSG\" with title \"$TITLE\" sound name \"Glass\"" 2>/dev/null; then
        notify_sent=true
    fi
elif is_wsl; then
    # WSL: PowerShell toast notification
    # Uses BurntToast module if available, falls back to simple toast
    if powershell.exe -Command "
        \$ErrorActionPreference = 'SilentlyContinue'
        if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast
            New-BurntToastNotification -Text '$TITLE', '$MSG'
        } else {
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
            [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
            \$template = '<toast><visual><binding template=\"ToastText02\"><text id=\"1\">$TITLE</text><text id=\"2\">$MSG</text></binding></visual></toast>'
            \$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
            \$xml.LoadXml(\$template)
            \$toast = [Windows.UI.Notifications.ToastNotification]::new(\$xml)
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('HYPE').Show(\$toast)
        }
    " 2>/dev/null; then
        notify_sent=true
    fi
else
    # Linux: notify-send (libnotify)
    if command -v notify-send &>/dev/null; then
        if notify-send "$TITLE" "$MSG" 2>/dev/null; then
            notify_sent=true
        fi
    fi
fi

# Always echo to terminal (fallback and for logs)
echo "🔔 $TITLE: $MSG"
