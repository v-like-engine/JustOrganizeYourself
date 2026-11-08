import hashlib
import json
import os
from pathlib import Path
import threading

import numpy as np

DEFAULT_MODEL = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
DEFAULT_REVISION = "faf4aa4225822f3bc6376869cb1164e8e3feedd0"
MODEL_LIMIT = 1_000_000_000


def model_path():
    return Path(os.environ.get("JOY_MODEL_PATH", Path.home() / ".local/share/joy/models/minilm"))


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def manifest_revision(files):
    return hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def verify_model(path):
    manifest = json.loads((path / "joy-model.json").read_text())
    files = manifest["files"]
    total = 0
    for name, info in files.items():
        local = path / name
        if not local.resolve().is_relative_to(path.resolve()):
            raise ValueError("Model manifest contains a path outside its directory")
        total += local.stat().st_size
        if local.stat().st_size != info["size"] or file_hash(local) != info["sha256"]:
            raise ValueError(f"Model file failed verification: {name}")
    if not files or total >= MODEL_LIMIT:
        raise ValueError("Model files must total less than 1 GB")
    if manifest["revision"] != manifest_revision(files):
        raise ValueError("Model manifest revision does not match its files")
    if manifest["modelFile"] not in files or not (path / manifest["modelFile"]).is_file():
        raise ValueError("Model weights are missing")
    return manifest


class LocalModel:
    def __init__(self, path=None):
        self.path = Path(path) if path else model_path()
        self.model = None
        self.detail = "Model is not installed. Run joy-embeddings install-model first."
        self.metadata = {"id": DEFAULT_MODEL, "revision": None, "dimensions": 384}
        self.lock = threading.Lock()
        self.tokenizer = None
        self.window = 126

    @property
    def loaded(self):
        return self.model is not None

    def load(self):
        if not (self.path / "joy-model.json").is_file():
            return
        try:
            manifest = verify_model(self.path)
            from fastembed import TextEmbedding

            specs = {entry["model"]: entry for entry in TextEmbedding.list_supported_models()}
            spec = specs.get(manifest["id"])
            if not spec or spec["model_file"] != manifest["modelFile"] or spec["dim"] != manifest["dimensions"]:
                raise ValueError("Model manifest does not match a supported model")
            self.model = TextEmbedding(
                model_name=manifest["id"],
                specific_model_path=str(self.path),
                local_files_only=True,
                threads=int(os.environ.get("JOY_MODEL_THREADS", "2")),
                providers=["CPUExecutionProvider"],
                enable_cpu_mem_arena=False,
            )
            tokenizer = self.model.model.tokenizer
            self.window = (tokenizer.truncation or {"max_length": 128})["max_length"] - tokenizer.num_special_tokens_to_add(False)
            self.tokenizer = tokenizer
            self.metadata = {
                "id": manifest["id"],
                "revision": manifest["revision"] + ".chunk-mean-v1",
                "dimensions": manifest["dimensions"],
            }
            self.detail = None
        except Exception as error:
            self.model = None
            self.detail = f"Local model could not be loaded: {error}"

    def embed(self, texts):
        if not self.loaded:
            raise RuntimeError(self.detail)
        with self.lock:
            chunks = []
            groups = []
            truncation = self.tokenizer.truncation
            self.tokenizer.no_truncation()
            try:
                for text in texts:
                    offsets = self.tokenizer.encode(text, add_special_tokens=False).offsets
                    weights = []
                    for start in range(0, len(offsets), self.window):
                        end = min(start + self.window, len(offsets))
                        chunks.append(text[offsets[start][0]:offsets[end-1][1]])
                        weights.append(end-start)
                    if not weights:
                        chunks.append(text)
                        weights.append(1)
                    groups.append(weights)
            finally:
                if truncation:
                    self.tokenizer.enable_truncation(**truncation)
            vectors = iter(self.model.embed(chunks, batch_size=16))
            result = []
            for weights in groups:
                vector = sum((next(vectors).astype(np.float64) * weight for weight in weights)) / sum(weights)
                length = np.linalg.norm(vector)
                if length:
                    vector /= length
                result.append(vector.tolist())
            return result
