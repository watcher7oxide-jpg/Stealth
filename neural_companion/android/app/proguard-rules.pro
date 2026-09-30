# Keep llama_flutter_android and JNI bindings
-keep class com.write4me.llama_flutter_android.** { *; }
-keep class kotlin.jvm.functions.Function1
-keepclassmembers class * implements kotlin.jvm.functions.Function1 {
    public java.lang.Object invoke(java.lang.Object);
}
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep Flutter and Pigeon wrappers
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.embedding.** { *; }
