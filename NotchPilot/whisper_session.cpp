// Private stdin/stdout transport; no listening socket and no audio retention.
#include "whisper.h"
#include "common-whisper.h"
#include "json.hpp"
#include <chrono>
#include <iostream>
#include <string>
using json = nlohmann::json;
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    auto params = whisper_context_default_params();
    params.flash_attn = true; // Match the pinned CLI’s optimized Metal path.
    whisper_context *ctx = whisper_init_from_file_with_params(argv[1], params);
    if (!ctx) return 3;
    std::cout << json({{"event", "ready"}}).dump() << std::endl;
    std::string line;
    while (std::getline(std::cin, line)) {
        std::string id;
        try {
            if (line.size() > 16384) throw std::runtime_error("Request too long");
            auto request = json::parse(line); id = request.at("id").get<std::string>();
            auto path = request.at("path").get<std::string>();
            std::vector<float> audio; std::vector<std::vector<float>> channels;
            if (!read_audio_data(path, audio, channels, false) || audio.size() > 16000 * 120)
                throw std::runtime_error("Invalid audio");
            auto start = std::chrono::steady_clock::now();
            auto p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
            p.n_threads = 4; p.language = "en"; p.no_context = true;
            p.print_realtime = false; p.print_progress = false;
            p.print_timestamps = false; p.print_special = false;
            // No command bias in continuous dictation: preserve the user's prose.
            std::string prompt = request.value("dictation", false) ? "" :
                "Voice commands for a Mac. Open TextEdit. Write a sentence. Type hello world.";
            p.initial_prompt = prompt.c_str();
            if (whisper_full(ctx, p, audio.data(), (int)audio.size()) != 0)
                throw std::runtime_error("Transcription failed");
            std::string text;
            for (int i = 0; i < whisper_full_n_segments(ctx); ++i) text += whisper_full_get_segment_text(ctx, i);
            double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
            std::cout << json({{"event","transcript"},{"id",id},{"text",text},{"seconds",seconds}}).dump() << std::endl;
        } catch (...) {
            std::cout << json({{"event","error"},{"id",id},{"text","Local speech recognition failed."}}).dump() << std::endl;
        }
    }
    whisper_free(ctx);
}
