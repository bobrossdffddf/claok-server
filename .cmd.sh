export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd /Users/wacko/Downloads/Cloak
pkill -f CloakInstaller
rm -rf dist
bash Scripts/build-installer.sh 2>&1 | tail -2
bash Scripts/build-dmg.sh 2>&1 | tail -1
cd dist && zip -qry CloakInstaller-macos.zip "Cloak Installer.app" && ls -lh
