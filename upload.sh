adb root
adb remount             # makes /system writable
adb push wait_boot /system/bin/wait_boot
adb shell chmod 755 /system/bin/wait_boot
adb push init.hotspot.sh /system/etc/
adb push lighttpd /data/local/lighttpd
adb shell chmod 755 /data/local/lighttpd
adb push lighttpd_lib /data/local/
adb push init.sun50iw9p1.rc /vendor/etc/init/hw/init.sun50iw9p1.rc
adb push dnsmasq /data/local/
adb shell chmod 755 /data/local/dnsmasq
adb push hostapd.conf /data/local/hostapd.conf