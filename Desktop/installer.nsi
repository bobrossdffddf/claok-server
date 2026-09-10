!include "MUI2.nsh"
!include "LogicLib.nsh"

; Passed in by the build so there is one version number in this project and
; not a second one that quietly goes stale.
!ifndef CLOAK_VERSION
  !define CLOAK_VERSION "0.0"
!endif
!ifndef CLOAK_BUILD
  !define CLOAK_BUILD "0"
!endif

Name "Cloak Installer ${CLOAK_VERSION}"
OutFile "..\dist\CloakInstaller-Setup.exe"
Unicode true
InstallDir "$LOCALAPPDATA\Cloak"
InstallDirRegKey HKCU "Software\Cloak" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma

VIProductVersion "${CLOAK_VERSION}.0.0"
VIAddVersionKey "ProductName" "Cloak Installer"
VIAddVersionKey "FileDescription" "Puts Cloak on your iPhone and keeps it there"
VIAddVersionKey "FileVersion" "${CLOAK_VERSION}.0.0"
VIAddVersionKey "ProductVersion" "${CLOAK_VERSION}"
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
    "DisplayVersion" "${CLOAK_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Cloak" \
    "Publisher" "Cloak"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Cloak" \
    "UninstallString" "$INSTDIR\Uninstall.exe"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Cloak" \
    "NoModify" 1

  WriteUninstaller "$INSTDIR\Uninstall.exe"

  Call CheckAppleDriver
SectionEnd

; Windows cannot see an iPhone on its own. The driver arrives with Apple's
; free Apple Devices app, or with iTunes on older machines. Every one of these
; keys is written by one of those, so any of them means the phone will be
; found.
Function CheckAppleDriver
  ClearErrors
  ReadRegStr $0 HKLM "SOFTWARE\Apple Inc.\Apple Mobile Device Support" "InstallDir"
  ${If} $0 != ""
    Return
  ${EndIf}

  ClearErrors
  ReadRegStr $0 HKLM "SOFTWARE\WOW6432Node\Apple Inc.\Apple Mobile Device Support" "InstallDir"
  ${If} $0 != ""
    Return
  ${EndIf}

  ClearErrors
  ReadRegStr $0 HKLM "SYSTEM\CurrentControlSet\Services\Apple Mobile Device Service" "ImagePath"
  ${If} $0 != ""
    Return
  ${EndIf}

  MessageBox MB_YESNO|MB_ICONINFORMATION \
    "One more thing.$\r$\n$\r$\nWindows needs Apple's free Apple Devices app before it can see an iPhone at all. Without it, Cloak Installer will not find your phone when you plug it in.$\r$\n$\r$\nOpen the Microsoft Store and get it now?" \
    IDNO done
    ExecShell "open" "ms-windows-store://search/?query=Apple%20Devices"
  done:
FunctionEnd

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
