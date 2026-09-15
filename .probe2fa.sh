#!/bin/bash
F=~/Library/Logs/Cloak/2fa-replay.txt
awk 'BEGIN{p=0} /^### GET https:\/\/gsa.apple.com\/auth$/{p=1;nl=0;next} /^###/{p=0} p&&/^-H /{sub(/^-H \x27/,"");sub(/\x27$/,"");L[nl++]=$0} END{for(i=0;i<nl;i++)print L[i]}' "$F" > /tmp/base.hdr
echo "base header lines: $(wc -l </tmp/base.hdr|tr -d ' ') (0=no capture)"
mk(){ grep -viE "^(x-mme-client-info|user-agent|x-xcode-version|x-apple-app-info):" /tmp/base.hdr > /tmp/v.hdr; for h in "$@"; do echo "$h" >> /tmp/v.hdr; done; }
go(){ c=$(curl -s -o /tmp/pb.txt -D /tmp/ph.txt -H 'Connection: close' -H @/tmp/v.hdr "$2" -w '%{http_code}'); printf '%-26s %s csp=%s bytes=%s %s\n' "$1" "$c" "$(grep -ci content-security-policy /tmp/ph.txt)" "$(wc -c </tmp/pb.txt|tr -d ' ')" "$(head -c 70 /tmp/pb.txt|tr -d '\n')"; sleep 1.5; }
AK='<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1>'
XC='<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.dt.Xcode/25183.54.10)>'
AKD='<MacBookPro18,3> <macOS;14.4.1;23E224> <com.apple.akd/1.0>'
mk "X-Mme-Client-Info: $AK" 'User-Agent: Xcode' 'X-Xcode-Version: 27.0 (27A5218g)' 'X-Apple-App-Info: com.apple.gs.xcode.auth'; go '1 AuthKit/Xcode/xc27' https://gsa.apple.com/auth
mk "X-Mme-Client-Info: $XC" 'User-Agent: Xcode' 'X-Xcode-Version: 11.2 (11B41)' 'X-Apple-App-Info: com.apple.gs.xcode.auth'; go '2 XcodeCard/Xcode' https://gsa.apple.com/auth
mk "X-Mme-Client-Info: $AKD" 'User-Agent: akd/1.0 CFNetwork/808.1.4' 'X-Apple-App-Info: com.apple.gs.xcode.auth'; go '3 akdCard/akd' https://gsa.apple.com/auth
mk "X-Mme-Client-Info: $AK" 'User-Agent: Xcode' 'X-Xcode-Version: 11.2 (11B41)' 'X-Apple-App-Info: com.apple.gs.xcode.auth'; go '4 AuthKit/Xcode/xc11' https://gsa.apple.com/auth
mk "X-Mme-Client-Info: $XC" 'User-Agent: Xcode' 'X-Xcode-Version: 11.2 (11B41)' 'X-Apple-App-Info: com.apple.gs.xcode.auth'; go '5 XcodeCard->trusteddev' https://gsa.apple.com/auth/verify/trusteddevice
echo DONE
