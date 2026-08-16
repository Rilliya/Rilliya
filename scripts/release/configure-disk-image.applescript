on run arguments
  set mountPath to item 1 of arguments
  set diskFolder to (POSIX file mountPath) as alias

  tell application "Finder"
    open diskFolder
    set diskWindow to container window of diskFolder
    set current view of diskWindow to icon view
    set toolbar visible of diskWindow to false
    set statusbar visible of diskWindow to false
    set bounds of diskWindow to {160, 120, 880, 560}

    set iconOptions to icon view options of diskWindow
    set arrangement of iconOptions to not arranged
    set icon size of iconOptions to 128
    set text size of iconOptions to 14
    set background picture of iconOptions to file ".background:RilliyaDiskImageBackground.png" of diskFolder

    set position of item "Rilliya.app" of diskFolder to {190, 195}
    set position of item "Applications" of diskFolder to {530, 195}

    update diskFolder without registering applications
    delay 1
    close diskWindow
  end tell
end run
