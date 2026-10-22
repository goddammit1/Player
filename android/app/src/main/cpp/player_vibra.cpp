// JNI-мост к Vibra для распознавания песен (SongRecognitionService.kt).
// Vibra бросает C++-исключения (std::runtime_error, std::bad_alloc), а
// исключение, пролетевшее через JNI, роняет процесс — здесь они
// превращаются в null.

#include <jni.h>

#include <string>

#include <vibra.h>

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_player_player_Vibra_nativeFingerprint(JNIEnv* env, jclass,
                                               jbyteArray pcm,
                                               jint sample_rate) {
  const jsize size = env->GetArrayLength(pcm);
  jbyte* bytes = env->GetByteArrayElements(pcm, nullptr);
  if (bytes == nullptr) return nullptr;

  std::string uri;
  unsigned int sample_ms = 0;
  try {
    Fingerprint* fingerprint = vibra_get_fingerprint_from_signed_pcm(
        reinterpret_cast<const char*>(bytes), size, sample_rate, 16, 1);
    if (fingerprint != nullptr) {
      const char* raw_uri = vibra_get_uri_from_fingerprint(fingerprint);
      if (raw_uri != nullptr) uri = raw_uri;
      sample_ms = vibra_get_sample_ms_from_fingerprint(fingerprint);
      vibra_free_fingerprint(fingerprint);
    }
  } catch (...) {
    uri.clear();
  }
  env->ReleaseByteArrayElements(pcm, bytes, JNI_ABORT);
  if (uri.empty()) return nullptr;

  // [uri, sampleMs] — два значения без отдельного Java-класса.
  jclass string_class = env->FindClass("java/lang/String");
  jobjectArray result = env->NewObjectArray(2, string_class, nullptr);
  env->SetObjectArrayElement(result, 0, env->NewStringUTF(uri.c_str()));
  env->SetObjectArrayElement(
      result, 1, env->NewStringUTF(std::to_string(sample_ms).c_str()));
  return result;
}
