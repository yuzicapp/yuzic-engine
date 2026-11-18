# The service is only ever named as a string — in the manifest, and by Media3's
# own SessionToken lookup — so nothing in the bytecode references it and R8 is
# entitled to conclude it is dead. It is not.
-keep class dev.yuzic.engine.PlaybackService { *; }

# Expo's Kotlin module registry finds this reflectively from
# expo-module.config.json, which R8 cannot see.
-keep class dev.yuzic.engine.YuzicEngineModule { *; }

# JNI entry points use this class and method names in every release build.
-keep,includedescriptorclasses class dev.yuzic.engine.NativeAlacDecoder {
    native <methods>;
}

# Records are constructed reflectively from the JS payload, field by field.
-keepclassmembers class dev.yuzic.engine.** {
  @expo.modules.kotlin.records.Field <fields>;
}
