# A ComfyUI custom-node bundle that registers server-side endpoints to download missing models into ComfyUI's `folder_paths`-resolved directories, plus a frontend extension that owns the progress UI. The `function downloadModel(...)` in comfyui-frontend-package's missingModelDownload-*.js is rewritten at frontend BUILD time (see flakes/comfyui-frontend-package/patch-download-model.py) to call `window.__wmi.start(model)`, which this extension provides.
#
# The output is just the source tree; ComfyUI scans the directory at startup. We bind-mount the store path read-only into /workspace/custom_nodes/web-model-installer at the service level (see modules/services/comfyui.nix).
{ stdenv, lib }:
stdenv.mkDerivation {
  pname = "comfyui-web-model-installer";
  version = "0";
  src = lib.cleanSource ./.;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r __init__.py web $out/
    runHook postInstall
  '';

  meta = {
    description = "ComfyUI custom node: server-side missing-models download for the web frontend.";
    platforms = lib.platforms.linux;
  };
}
