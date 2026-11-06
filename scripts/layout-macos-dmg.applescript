-- Finder's installed scripting dictionary is the API contract for these settings.
-- Configure the mounted writable volume so its background alias stays on-volume.
on run argv
    set mountedFolder to POSIX file (item 1 of argv) as alias
    tell application "Finder"
        set volumeFolder to folder mountedFolder
        open volumeFolder
        tell container window of volumeFolder
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set pathbar visible to false
            set bounds to {200, 140, 920, 662}
            tell its icon view options
                set arrangement to not arranged
                set icon size to 96
                set text size to 14
                set label position to bottom
                set shows item info to false
                set shows icon preview to true
                set background picture to file ".background:installer.tiff" of volumeFolder
            end tell
        end tell
        -- Reopen after hiding Finder bars; otherwise it offsets saved Y positions.
        close container window of volumeFolder
        open volumeFolder
        delay 1
        set position of item "Flow Quota.app" of volumeFolder to {180, 180}
        set position of item "Applications" of volumeFolder to {540, 180}
        set position of item "安装说明.txt" of volumeFolder to {610, 370}
        update volumeFolder without registering applications
        delay 1
        close container window of volumeFolder
        -- Reopen once to flush and verify Finder's saved icon view before compression.
        open volumeFolder
        delay 1
        tell container window of volumeFolder
            if current view is not icon view then error "Finder did not save icon view."
        end tell
        if position of item "Flow Quota.app" of volumeFolder is not {180, 180} then ¬
            error ("Finder did not save app position: " & (position of item "Flow Quota.app" of volumeFolder as text))
        if position of item "Applications" of volumeFolder is not {540, 180} then ¬
            error ("Finder did not save Applications position: " & (position of item "Applications" of volumeFolder as text))
        close container window of volumeFolder
    end tell
end run
