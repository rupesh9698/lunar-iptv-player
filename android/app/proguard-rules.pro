# R8 rules for release builds (code shrinking + obfuscation).
# Flutter's own rules are added by the Flutter Gradle plugin.

# media_kit: the video player's Android helper is called from native /
# Dart code by name, so R8 must not rename or remove it.
-keep class com.alexmercerind.** { *; }

# package:jni (used by media_kit and others): Java classes are looked up by
# name from Dart.
-keep class com.github.dart_lang.jni.** { *; }

# Plugins whose classes are registered by name from GeneratedPluginRegistrant.
-keep class io.flutter.plugins.** { *; }
-keep class dev.fluttercommunity.plus.** { *; }

# Flutter references Play Core (deferred components) optionally; the app
# doesn't ship it, so don't fail the build on the missing classes.
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# Keep native method names (JNI) and enums used by plugins via reflection.
-keepclasseswithmembernames class * {
    native <methods>;
}
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Stack traces in Play Console: keep line numbers (mapping file is uploaded
# with the bundle).
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
