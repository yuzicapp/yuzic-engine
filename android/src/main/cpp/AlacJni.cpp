#include "AlacDecoder.h"
#include <jni.h>
#include <stdexcept>

static void fail(JNIEnv *env, const char *message) {
  env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), message);
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_yuzic_engine_NativeAlacDecoder_create(JNIEnv *env, jclass, jbyteArray config) {
  if (!config || env->GetArrayLength(config) != 24) {
    fail(env, "Expected 24-byte ALAC configuration"); return 0;
  }
  uint8_t cookie[24];
  env->GetByteArrayRegion(config, 0, 24, reinterpret_cast<jbyte *>(cookie));
  if (env->ExceptionCheck()) return 0;
  try { return reinterpret_cast<jlong>(new yuzic::AlacDecoder(cookie, 24)); }
  catch (const std::exception &error) { fail(env, error.what()); return 0; }
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_yuzic_engine_NativeAlacDecoder_decode(JNIEnv *env, jclass, jlong handle,
    jobject input, jint offset, jint size, jobject output, jint capacity) {
  auto *decoder = reinterpret_cast<yuzic::AlacDecoder *>(handle);
  auto *in = static_cast<uint8_t *>(env->GetDirectBufferAddress(input));
  auto *out = static_cast<uint8_t *>(env->GetDirectBufferAddress(output));
  jlong inCapacity = env->GetDirectBufferCapacity(input);
  jlong outCapacity = env->GetDirectBufferCapacity(output);
  if (!decoder || !in || !out || offset < 0 || size < 0 || capacity < 0
      || jlong(offset) + size > inCapacity || capacity > outCapacity) {
    fail(env, "Invalid ALAC direct buffers"); return 0;
  }
  try { return static_cast<jint>(decoder->decode(in + offset, size, out, capacity)); }
  catch (const std::exception &error) { fail(env, error.what()); return 0; }
}

extern "C" JNIEXPORT void JNICALL
Java_dev_yuzic_engine_NativeAlacDecoder_destroy(JNIEnv *, jclass, jlong handle) {
  delete reinterpret_cast<yuzic::AlacDecoder *>(handle);
}

extern "C" JNIEXPORT void JNICALL
Java_dev_yuzic_engine_NativeAlacDecoder_flush(JNIEnv *, jclass, jlong handle) {
  reinterpret_cast<yuzic::AlacDecoder *>(handle)->flush();
}
