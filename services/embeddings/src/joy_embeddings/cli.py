import argparse
import hashlib
import json
from pathlib import Path

from .model import DEFAULT_MODEL, DEFAULT_REVISION, MODEL_LIMIT, file_hash, manifest_revision, model_path


def install_model(destination, name=DEFAULT_MODEL, revision=None):
    from fastembed import TextEmbedding
    from huggingface_hub import HfApi, snapshot_download

    models = {item["model"]: item for item in TextEmbedding.list_supported_models()}
    if name not in models:
        raise ValueError("Model is not supported by the installed fastembed version")
    spec = models[name]
    if spec["size_in_GB"] >= 1:
        raise ValueError("Choose a model smaller than 1 GB")
    repo = spec["sources"].get("hf")
    if not repo:
        raise ValueError("Model has no supported Hugging Face source")
    selected = revision or (DEFAULT_REVISION if name == DEFAULT_MODEL else "main")
    info = HfApi().model_info(repo, revision=selected, files_metadata=True)
    selected_files = [
        file for file in info.siblings
        if file.rfilename in {spec["model_file"], *spec.get("additional_files", [])}
        or file.rfilename.endswith((".json", ".txt", ".md"))
    ]
    if not selected_files or sum(file.size or 0 for file in selected_files) >= MODEL_LIMIT:
        raise ValueError("Model files must total less than 1 GB")
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    marker = destination / "joy-model.json"
    if marker.exists():
        raise ValueError("A model is already installed at this location; choose another directory")
    snapshot_download(
        repo_id=repo,
        revision=info.sha,
        allow_patterns=[file.rfilename for file in selected_files],
        local_dir=destination,
        max_workers=3,
    )
    files = {}
    for remote in selected_files:
        path = destination / remote.rfilename
        digest = file_hash(path)
        if path.stat().st_size != remote.size:
            raise ValueError(f"Model file size does not match source: {remote.rfilename}")
        if remote.lfs:
            if digest != remote.lfs.sha256:
                raise ValueError(f"Model file checksum does not match source: {remote.rfilename}")
        else:
            payload = path.read_bytes()
            blob = hashlib.sha1(f"blob {len(payload)}\0".encode() + payload).hexdigest()
            if blob != remote.blob_id:
                raise ValueError(f"Model file checksum does not match source: {remote.rfilename}")
        files[remote.rfilename] = {"sha256": digest, "size": path.stat().st_size}
    if sum(file["size"] for file in files.values()) >= MODEL_LIMIT:
        raise ValueError("Model files must total less than 1 GB")
    manifest = {
        "id": name,
        "revision": manifest_revision(files),
        "dimensions": spec["dim"],
        "modelFile": spec["model_file"],
        "source": repo,
        "sourceRevision": info.sha,
        "license": spec["license"],
        "files": files,
    }
    temporary = destination / "joy-model.json.tmp"
    temporary.write_text(json.dumps(manifest, indent=2) + "\n")
    temporary.replace(marker)
    return manifest


def main():
    parser = argparse.ArgumentParser(prog="joy-embeddings")
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8766)
    install = commands.add_parser("install-model")
    install.add_argument("--path", type=Path, default=model_path())
    install.add_argument("--name", default=DEFAULT_MODEL)
    install.add_argument("--revision")
    args = parser.parse_args()
    if args.command == "serve":
        import uvicorn

        uvicorn.run("joy_embeddings.api:app", host=args.host, port=args.port)
    else:
        manifest = install_model(args.path, args.name, args.revision)
        print(json.dumps({"path": str(args.path), "model": manifest["id"], "revision": manifest["revision"], "bytes": sum(info["size"] for info in manifest["files"].values())}))


if __name__ == "__main__":
    main()
