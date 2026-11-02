# ONNX JNI looks up Java classes/members by their original names.
# https://onnxruntime.ai/docs/build/android.html
-keep class ai.onnxruntime.** { *; }

# Official Vosk Android demo JNI/JNA retention rules.
-keep class com.sun.jna.** { *; }
-keep class org.vosk.** { *; }
-keepclassmembers class * extends com.sun.jna.* { public *; }
-dontwarn java.awt.**
