# ComfyUI is a Python application laid out as a `main.py` at the root of its source tree, plus `comfy/`, `comfy_extras/`, etc. as importable subpackages — no `[project.scripts]` in upstream pyproject.toml. So we package it kapowarr-style: build a python env with the runtime deps via the overlay-augmented python3 scope, splat the source tree into `$out/lib/comfyui/`, and produce a `bin/comfyui` wrapper that execs the env's python on `main.py`. The wrapper's python is hard-pinned (no PATH dependency at runtime); `meta.mainProgram` makes `lib.getExe` resolve correctly inside `homelab.images.comfyui`.
{ stdenv
, lib
, makeWrapper
, python3
, src
, version
}:
let
  python = python3.withPackages (ps: with ps; [
    # Core deep-learning stack — CUDA variants when nixpkgs is imported with cudaSupport (set in modules/nvidia.nix on consumer machines).
    torch
    torchvision
    torchsde
    torchaudio
    # Numerics + tensor utilities
    numpy
    einops
    scipy
    # Transformers / tokenization
    transformers
    tokenizers
    sentencepiece
    safetensors
    # Web/HTTP server stack
    aiohttp
    yarl
    pyyaml
    requests
    # Imaging / media
    pillow
    av
    # DB / migrations (ComfyUI grew an alembic-backed user/history store)
    alembic
    sqlalchemy
    filelock
    # Misc runtime
    tqdm
    psutil
    simpleeval
    blake3
    # Image processing extras
    kornia
    # Pydantic v2 + settings
    pydantic
    pydantic-settings
    # OpenGL bindings (used by some preview / display nodes)
    pyopengl
    glfw
    # Pip stays in the env so ComfyUI-Manager's `pip install --user` writes into PYTHONUSERBASE at runtime (see modules/services/comfyui.nix).
    pip
    # ComfyUI-Manager's own startup deps (its requirements.txt). Bake them in so Manager loads cleanly without trying to pip-install at first boot (which hits PEP 668's externally-managed-environment marker on the Nix-built python and fails). Manager-installed custom nodes still get their deps via runtime pip --user (gated by PIP_BREAK_SYSTEM_PACKAGES, set in modules/services/comfyui.nix); these here are just the dependencies of Manager itself.
    gitpython
    pygithub
    matrix-nio
    huggingface-hub
    typer
    rich
    toml
    uv
    chardet
    # PyPI-only siblings, injected by the per-dep flakes/<name> sub-flakes via the wrapper flake's overlay.
    spandrel
    comfyui-frontend-package
    comfyui-workflow-templates
    comfyui-embedded-docs
    comfy-kitchen
    comfy-aimdo
  ]);
in
stdenv.mkDerivation {
  pname = "comfyui";
  inherit version src;

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  # `comfy/` is a PEP 420 namespace package upstream (no __init__.py). aiohttp's `--listen ::` opens an IPv6-only socket — the macvlan IPv4 gets connection-refused, breaking external reachability. Drop an __init__.py that monkey-patches socket.setsockopt to discard `IPV6_V6ONLY=1` before any server bind happens; main.py's first line is `import comfy.options`, so this runs before anything else. Same mechanism as lib.homelab.withPythonDualStackIPv6, replicated inline because that helper targets buildPythonPackage and this is stdenv.mkDerivation.
  postPatch = ''
    cp ${./dual-stack-ipv6.py} comfy/__init__.py
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/comfyui $out/bin
    cp -r . $out/lib/comfyui/

    # `--add-flags main.py` so callers pass through to ComfyUI (`comfyui --listen ::`). makeWrapper preserves "$@". The wrapper hard-codes the env-wrapped interpreter with PYTHONPATH baked in, so it works regardless of caller PATH. `--chdir` makes ComfyUI's __file__-relative and cwd-relative path lookups (nodes.py, comfy_extras) resolve against our installed source tree.
    makeWrapper ${lib.getExe' python "python3"} $out/bin/comfyui \
      --add-flags "$out/lib/comfyui/main.py" \
      --chdir "$out/lib/comfyui"

    runHook postInstall
  '';

  passthru = {
    inherit python;
  };

  meta = {
    description = "ComfyUI: node-based AI image/video generation runtime.";
    homepage = "https://github.com/comfyanonymous/ComfyUI";
    license = lib.licenses.gpl3Only;
    mainProgram = "comfyui";
    platforms = lib.platforms.linux;
  };
}
