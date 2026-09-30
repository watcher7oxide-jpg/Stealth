# 1. Ignore optional Play Core dependencies referenced by Flutter engine
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
-dontwarn io.flutter.embedding.android.FlutterPlayStoreSplitApplication

# 2. Keep llama_flutter_android and JNI native bindings
-keep class com.write4me.llama_flutter_android.** { *; }
-keep class kotlin.jvm.functions.Function1
-keepclassmembers class * implements kotlin.jvm.functions.Function1 {
    public java.lang.Object invoke(java.lang.Object);
}
-keepclasseswithmembernames class * {
    native <methods>;
}

# 3. Keep Flutter and Pigeon wrappers
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.embedding.** { *; }
