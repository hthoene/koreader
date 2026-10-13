; KOReader installer (NSIS 3).
;
; Expected definitions (c.f. `make/win32.mk`):
; - VERSION: KOReader version (e.g. `v2026.07.2-241-g3bfdadcb5_2026-10-13`)
; - VERSION_NUM: numeric version (e.g. `2026.7.2.241`)
; - SRC_DIR: directory with the files to install
; - FILES_LIST: list of the installed files (c.f. `gen_files_list.sh`)
; - OUT_FILE: path of the generated installer
; - ICON: path to the application icon
; - LICENSE: path to the license file

Unicode true
SetCompressor /SOLID lzma
ManifestDPIAware true
ManifestSupportedOS Win10

!define APP_NAME "KOReader"
!define APP_EXE "koreader.exe"
!define APP_ID "KOReader"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}"
!define APP_PATHS_KEY "Software\Microsoft\Windows\CurrentVersion\App Paths\${APP_EXE}"
!define APPLICATION_KEY "Software\Classes\Applications\${APP_EXE}"
!define PROGID "KOReader.Document"

Name "${APP_NAME}"
OutFile "${OUT_FILE}"
Icon "${ICON}"
UninstallIcon "${ICON}"
BrandingText "${APP_NAME} ${VERSION}"

VIProductVersion "${VERSION_NUM}"
VIAddVersionKey "ProductName" "${APP_NAME}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "${APP_NAME} installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "GNU AGPL v3"

; Per-user installation: no administrator rights needed (no UAC prompt).
RequestExecutionLevel user
InstallDir "$LOCALAPPDATA\Programs\${APP_NAME}"
InstallDirRegKey HKCU "${UNINSTALL_KEY}" "InstallLocation"

!include MUI2.nsh
!include FileFunc.nsh
!include LogicLib.nsh

!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_NOREBOOTSUPPORT

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${LICENSE}"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

; File types offered in the "Open with" menu (the default handlers are left alone). {{{

!macro ForEachFileType MACRO
    !insertmacro ${MACRO} "azw"
    !insertmacro ${MACRO} "cbr"
    !insertmacro ${MACRO} "cbt"
    !insertmacro ${MACRO} "cbz"
    !insertmacro ${MACRO} "chm"
    !insertmacro ${MACRO} "djv"
    !insertmacro ${MACRO} "djvu"
    !insertmacro ${MACRO} "epub"
    !insertmacro ${MACRO} "fb2"
    !insertmacro ${MACRO} "fb3"
    !insertmacro ${MACRO} "mobi"
    !insertmacro ${MACRO} "oxps"
    !insertmacro ${MACRO} "pdb"
    !insertmacro ${MACRO} "pdf"
    !insertmacro ${MACRO} "prc"
    !insertmacro ${MACRO} "xps"
!macroend

!macro RegisterFileType EXT
    WriteRegStr HKCU "${APPLICATION_KEY}\SupportedTypes" ".${EXT}" ""
    WriteRegStr HKCU "Software\Classes\.${EXT}\OpenWithProgids" "${PROGID}" ""
!macroend

!macro UnregisterFileType EXT
    DeleteRegValue HKCU "Software\Classes\.${EXT}\OpenWithProgids" "${PROGID}"
!macroend

; }}}

Section "${APP_NAME}" SecMain
    SectionIn RO
    SetOutPath "$INSTDIR"

    ; Upgrade: remove the files installed by the previous version (using its
    ; own uninstaller, which knows the exact list). The user data is kept.
    IfFileExists "$INSTDIR\uninstall.exe" 0 +2
        ExecWait '"$INSTDIR\uninstall.exe" /S /UPGRADE _?=$INSTDIR'

    File /r "${SRC_DIR}\*.*"

    WriteUninstaller "$INSTDIR\uninstall.exe"

    ; Start menu shortcut.
    CreateShortcut "$SMPROGRAMS\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"

    ; "Open with" support.
    WriteRegStr HKCU "${APPLICATION_KEY}" "FriendlyAppName" "${APP_NAME}"
    WriteRegStr HKCU "${APPLICATION_KEY}\DefaultIcon" "" "$INSTDIR\${APP_EXE},0"
    WriteRegStr HKCU "${APPLICATION_KEY}\shell\open\command" "" '"$INSTDIR\${APP_EXE}" "%1"'
    WriteRegStr HKCU "Software\Classes\${PROGID}" "" "${APP_NAME} document"
    WriteRegStr HKCU "Software\Classes\${PROGID}\DefaultIcon" "" "$INSTDIR\${APP_EXE},0"
    WriteRegStr HKCU "Software\Classes\${PROGID}\shell\open\command" "" '"$INSTDIR\${APP_EXE}" "%1"'
    !insertmacro ForEachFileType RegisterFileType

    ; App path (so `koreader` can be started from the "Run" dialog).
    WriteRegStr HKCU "${APP_PATHS_KEY}" "" "$INSTDIR\${APP_EXE}"

    ; Uninstall information.
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${APP_NAME}"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\${APP_EXE},0"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "KOReader contributors"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "URLInfoAbout" "https://koreader.rocks"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
    WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
    WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
    ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
    WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" $0

    ; Notify the shell of the file associations changes (`SHCNE_ASSOCCHANGED`).
    System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
SectionEnd

Section "Desktop shortcut" SecDesktop
    CreateShortcut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
    !insertmacro MUI_DESCRIPTION_TEXT ${SecMain} "The ${APP_NAME} application."
    !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} "Create a shortcut on the desktop."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Section "Uninstall"
    ${GetParameters} $0
    ClearErrors
    ${GetOptions} $0 "/UPGRADE" $1
    ${If} ${Errors}
        ; Files KOReader itself creates in its installation directory (kept on upgrade).
        Delete "$INSTDIR\version.log"
        Delete "$INSTDIR\data\cr3.ini"
    ${EndIf}

    ; Only remove the files we installed (and the then empty directories):
    ; the user data is stored elsewhere, and is kept.
    !include "${FILES_LIST}"
    Delete "$INSTDIR\uninstall.exe"
    RMDir "$INSTDIR"

    Delete "$SMPROGRAMS\${APP_NAME}.lnk"
    Delete "$DESKTOP\${APP_NAME}.lnk"

    !insertmacro ForEachFileType UnregisterFileType
    DeleteRegKey HKCU "Software\Classes\${PROGID}"
    DeleteRegKey HKCU "${APPLICATION_KEY}"
    DeleteRegKey HKCU "${APP_PATHS_KEY}"
    DeleteRegKey HKCU "${UNINSTALL_KEY}"

    System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
SectionEnd

; vim: foldmethod=marker foldlevel=0
