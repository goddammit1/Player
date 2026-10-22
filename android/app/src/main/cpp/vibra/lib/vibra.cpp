#include "../include/vibra.h"

#include <cstdlib>
#include <cstring>
#include <string>

#include "algorithm/signature_generator.h"
#include "audio/downsampler.h"
#include "audio/wav.h"
#include "utils/ffmpeg.h"

struct Fingerprint {
  char* uri;
  unsigned int sample_ms;
};

namespace vibra {

constexpr std::uint32_t kMaxDurationSeconds = 12;

char* CopyString(const std::string& value) {
  auto* copy = static_cast<char*>(std::malloc(value.size() + 1));
  if (copy == nullptr) {
    return nullptr;
  }
  std::memcpy(copy, value.c_str(), value.size() + 1);
  return copy;
}

Fingerprint* MakeFingerprint(const Signature& signature) {
  auto* fingerprint =
      static_cast<Fingerprint*>(std::malloc(sizeof(Fingerprint)));
  if (fingerprint == nullptr) {
    return nullptr;
  }

  const std::string kUri = signature.EncodeBase64();
  fingerprint->uri = CopyString(kUri);
  if (fingerprint->uri == nullptr) {
    std::free(fingerprint);
    return nullptr;
  }

  fingerprint->sample_ms =
      signature.num_samples() * 1000 / signature.sample_rate();
  return fingerprint;
}

Fingerprint* GetFingerprintFromLowQualityPcm(const LowQualityTrack& pcm) {
  SignatureGenerator generator;
  generator.FeedInput(pcm);
  generator.set_max_time_seconds(kMaxDurationSeconds);

  return MakeFingerprint(generator.GetNextSignature());
}

Fingerprint* GetFingerprintFromWav(const Wav& wav) {
  LowQualityTrack pcm = Downsampler::GetLowQualityPCM(wav);
  return GetFingerprintFromLowQualityPcm(pcm);
}

}  // namespace vibra

Fingerprint* vibra_get_fingerprint_from_music_file(
    const char* music_file_path) {
  std::string path = music_file_path;
  if (path.size() >= 4 && path.substr(path.size() - 4) == ".wav") {
    vibra::Wav wav = vibra::Wav::FromFile(path);
    return vibra::GetFingerprintFromWav(wav);
  }

  vibra::LowQualityTrack pcm =
      vibra::ffmpeg::FFmpegWrapper::ConvertToLowQaulityPcm(
          path, 0, vibra::kMaxDurationSeconds);
  return vibra::GetFingerprintFromLowQualityPcm(pcm);
}

Fingerprint* vibra_get_fingerprint_from_wav_data(const char* raw_wav,
                                                 int wav_data_size) {
  vibra::Wav wav = vibra::Wav::FromRawWav(raw_wav, wav_data_size);
  return vibra::GetFingerprintFromWav(wav);
}

Fingerprint* vibra_get_fingerprint_from_signed_pcm(const char* raw_pcm,
                                                   int pcm_data_size,
                                                   int sample_rate,
                                                   int sample_width,
                                                   int channel_count) {
  vibra::Wav wav = vibra::Wav::FromSignedPCM(
      raw_pcm, pcm_data_size, sample_rate, sample_width, channel_count);
  return vibra::GetFingerprintFromWav(wav);
}

Fingerprint* vibra_get_fingerprint_from_float_pcm(const char* raw_pcm,
                                                  int pcm_data_size,
                                                  int sample_rate,
                                                  int sample_width,
                                                  int channel_count) {
  vibra::Wav wav = vibra::Wav::FromFloatPCM(raw_pcm, pcm_data_size, sample_rate,
                                            sample_width, channel_count);
  return vibra::GetFingerprintFromWav(wav);
}

const char* vibra_get_uri_from_fingerprint(const Fingerprint* fingerprint) {
  return fingerprint->uri;
}

unsigned int vibra_get_sample_ms_from_fingerprint(
    const Fingerprint* fingerprint) {
  return fingerprint->sample_ms;
}

void vibra_free_fingerprint(Fingerprint* fingerprint) {
  if (fingerprint == nullptr) {
    return;
  }

  std::free(fingerprint->uri);
  std::free(fingerprint);
}
