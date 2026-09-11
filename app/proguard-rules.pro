# R8 rules for the release build.

# kotlinx.serialization resolves serializers reflectively through the generated
# Companion and $$serializer members, which R8 otherwise sees as unreachable.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**

-if @kotlinx.serialization.Serializable class com.shotclubhouse.sayso.**
-keepclassmembers class com.shotclubhouse.sayso.** {
    *** Companion;
}
-if @kotlinx.serialization.Serializable class com.shotclubhouse.sayso.**
-keepclasseswithmembers class com.shotclubhouse.sayso.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.shotclubhouse.sayso.**$$serializer { *; }

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
