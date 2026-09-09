!include "MUI2.nsh"
!include "LogicLib.nsh"

Name "Cloak Installer"
OutFile "..\dist\CloakInstaller-Setup.exe"
Unicode true
InstallDir "$LOCALAPPDATA\Cloak"
InstallDirRegKey HKCU "Software\Cloak" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma

VIProductVersion "1.0.0.0"
VIAddVersionKey "ProductName" "Cloak Installer"
VIAddVersionKey "FileDescription" "Puts Cloak on your iPhone and keeps it there"
VIAddVersionKey "FileVersion" "1.0.0.0"
VIAddVersionKey "ProductVersion" "1.0.0"
VIAddVersionKey "LegalCopyright" "Cloak"

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\CloakInstaller.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Open Cloak Installer now"

!insertmacro MUI_PAGE_LICENSE "..\LICENSE.txt"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Section "Cloak Installer" SecMain
  SetOutPath "$INSTDIR"
  File "..\dist\CloakInstaller\CloakInstaller.exe"
  File /nonfatal "..\dist\CloakInstaller\Cloak.ipa"
  File /nonfatal "..\dist\CloakInstaller\README.txt"

  WriteRegStr HKCU "Software\Cloak" "InstallDir" "$INSTDIR"

  CreateDirectory "$SMPROGRAMS\Cloak"
  CreateShortcut "$SMPROGRAMS\Cloak\Cloak Installer.lnk" "$INSTDIR\CloakInstaller.exe"
  CreateShortcut "$DESKTOP\Cloak Installer.lnk" "$INSTDIR\CloakInstaller.exe"

  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Cloak" \
    "DisplayName" "Cloak Installer"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Cloak" \
    "DisplayIcon" "$INSTDIR\CloakInstaller.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Cloak" \
    "DisplayVersion" "1.0.0"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Cloak" \
    "Publisher" "Cloak"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Cloak" \
    "UninstallString" "$INSTDIR\Uninstall.exe"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Cloak" \
    "NoModify" 1

  WriteUninstaller "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Uninstall"
  ; The scheduled renewal job belongs to this install, so it goes with it.
  nsExec::Exec 'schtasks /Delete /F /TN "Cloak Refresh"'

  Delete "$INSTDIR\CloakInstaller.exe"
  Delete "$INSTDIR\Cloak.ipa"
  Delete "$INSTDIR\README.txt"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"

  Delete "$SMPROGRAMS\Cloak\Cloak Installer.lnk"
  RMDir "$SMPROGRAMS\Cloak"
  Delete "$DESKTOP\Cloak Installer.lnk"

  DeleteRegKey HKCU "Software\Cloak"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Cloak"
SectionEnd
