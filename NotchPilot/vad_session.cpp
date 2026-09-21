// Private binary stream for the bundled Silero VAD. The helper never listens on
// a network port and only receives 512-sample, mono 16 kHz audio frames.
#include "whisper.h"
#include "ggml-backend.h"

#include <cstdint>
#include <iostream>
#include <vector>

namespace {
constexpr size_t kFrameSamples = 512;
void quiet_log(enum ggml_log_level, const char *, void *) {}
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    whisper_log_set(quiet_log, nullptr);
    ggml_backend_load_all();
    auto params = whisper_vad_default_context_params();
    params.n_threads = 2;
    params.use_gpu = false;
    auto *vad = whisper_vad_init_from_file_with_params(argv[1], params);
    if (!vad) return 3;

    std::cout << "{\"event\":\"ready\"}\n" << std::flush;
    char operation = 0;
    std::vector<float> frame(kFrameSamples);
    while (std::cin.read(&operation, 1)) {
        if (operation == 'R') {
            whisper_vad_reset_state(vad);
            continue;
        }
        if (operation != 'F' || !std::cin.read(reinterpret_cast<char *>(frame.data()), sizeof(float) * frame.size())) break;
        float probability = -1;
        if (whisper_vad_detect_speech_no_reset(vad, frame.data(), static_cast<int>(frame.size())) && whisper_vad_n_probs(vad) == 1) {
            probability = whisper_vad_probs(vad)[0];
        }
        std::cout.write(reinterpret_cast<const char *>(&probability), sizeof(probability));
        std::cout.flush();
    }
    whisper_vad_free(vad);
}
