# Source this before building:  source tools/env.sh
export ANDROID_HOME=/home/codespace/Android/Sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/23.2.8568313
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH=$JAVA_HOME/bin:$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin:$ANDROID_HOME/platform-tools:$PATH
export ARCH=linux-x86_64
