#!/bin/zsh
# Instala DeskWidgets como LaunchAgent para que arranque al iniciar sesión.
DIR=${0:A:h}
BIN=$DIR/DeskWidgets
LABEL=com.claudemacwidgets.deskwidgets
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist

# compila solo si falta el binario
[[ -x $BIN ]] || (cd $DIR && swiftc -O DeskWidgets.swift -o DeskWidgets) || exit 1

mkdir -p ${PLIST:h}
# KeepAlive SuccessfulExit=false: si crashea relanza; Quit (exit 0) queda cerrado
cat > $PLIST <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PL
plutil -lint $PLIST || exit 1

# detiene instancia manual y recarga el agente
pkill -x DeskWidgets
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null
launchctl bootstrap gui/$(id -u) $PLIST
