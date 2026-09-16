# R8 rules for the release build.

# kotlinx.serialization resolves serializers reflectively through the generated
# Companion and $$serializer members, which R8 otherwise sees as unreachable.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**

-if @kotlinx.serialization.Serializable class ai.sayso.dictation.**
-keepclassmembers class ai.sayso.dictation.** {
    *** Companion;
}
-if @kotlinx.serialization.Serializable class ai.sayso.dictation.**
-keepclasseswithmembers class ai.sayso.dictation.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class ai.sayso.dictation.**$$serializer { *; }

# sherpa-onnx is called from native code, so its classes and members are reached
# by JNI name lookup rather than from any Kotlin call site.
-keep class com.k2fsa.sherpa.onnx.** { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}

# OkHttp names optional TLS and BouncyCastle providers that are not on Android.
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
