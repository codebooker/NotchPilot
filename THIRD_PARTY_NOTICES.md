# Third-party notices

The repository retains its existing GNU AGPL v3 license in [LICENSE](LICENSE). Upstream dependencies and separately downloaded models retain their respective licenses. This file identifies major components; it does not replace their license texts.

| Component | Source / pin | Notice |
|---|---|---|
| Cua Driver | `cua-driver==0.28.2`, [trycua/cua](https://github.com/trycua/cua) | The embedded binary’s MIT notice is included in [NotchPilot/CUA-LICENSE.txt](NotchPilot/CUA-LICENSE.txt) and copied into app resources. |
| TypeSafe computer use | [awlevin/typesafe-computer-use](https://github.com/awlevin/typesafe-computer-use), `cc7b5066ae1a07b5e3182e8f87a9b5b6dfdcffc1` | Setup fetches its source; the build copies its LICENSE into app resources. |
| Jev ultrafast | [browser-use/jev-ultrafast](https://github.com/browser-use/jev-ultrafast), `1231850a0bf1a0c0341fe408ef1668dbbfdfac46` | Setup fetches its source; the build copies its LICENSE into app resources. |
| whisper.cpp | [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp), `5670d5c0bbcb148feabef84400a07cfca9aa3b30` | Setup fetches its source; the build copies its LICENSE into app resources. |
| MLX LM | [ml-explore/mlx-lm](https://github.com/ml-explore/mlx-lm), `mlx-lm==0.31.3` | Installed in the local runtime; see the upstream package license. |
| Whisper / Qwen weights | Pinned file URLs and SHA-256 values in [NotchPilot/models.json](NotchPilot/models.json) | Downloaded separately; consult each model repository’s license and model card. |

Other Python dependencies are installed by setup and retain their package notices. No third-party model weights or cached upstream repositories are committed here. The README’s SVG is an original interface illustration; its cursor preview comes from NotchPilot’s native renderer. macOS interface symbols used by the app are provided by the system.
