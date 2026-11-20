{ fetchurl }:
let
  revision = "5359861c739e955e79d9a303bcbc70fb988958b1";
  model =
    name: hash:
    fetchurl {
      url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/${revision}/ggml-${name}.bin";
      inherit hash;
    };
in
{
  large-v3-turbo = model "large-v3-turbo" "sha256:1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69";
  tiny-en = model "tiny.en" "sha256:921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f";
}
