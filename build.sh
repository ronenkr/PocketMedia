export NDK=$HOME/Android/Sdk/ndk/android-ndk-r25c
$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi21-clang -Os -fPIE -pie -s -o wait_boot wait_boot.c

adb root
adb remount             # makes /system writable
adb push wait_boot /system/bin/wait_boot
adb shell chmod 755 /system/bin/wait_boot
