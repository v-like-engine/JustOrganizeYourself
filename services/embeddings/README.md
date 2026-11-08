# Local semantic embeddings

An optional Python service for JOY's Knowledge and Contacts graph. The Flutter app and its local SQLite database work without it. This service does not classify tasks into folders, train a model, or contact a cloud inference API.

## Install and start

Python 3.11 or newer is required. From the repository root:

```sh
python -m venv services/embeddings/.venv
services/embeddings/.venv/bin/python -m pip install -e 'services/embeddings[dev,model]'
services/embeddings/.venv/bin/joy-embeddings serve
```

On Windows, use `.venv\Scripts\python.exe` and `.venv\Scripts\joy-embeddings.exe`. `requirements-dev.lock` records the tested environment including the optional model and test dependencies. To reproduce those versions, install it with `pip install -r services/embeddings/requirements-dev.lock`, then install the package with `pip install --no-deps -e services/embeddings`.

The default listener is `127.0.0.1:8766`. Startup loads only an explicitly installed local model. It never downloads weights. Without weights, `/health` reports `model_unavailable`, embedding requests return HTTP 503, and `/v1/graph` remains available for previously stored vectors.

If only the graph API is needed, install `services/embeddings[dev]` without the `model` extra. For another trusted device on the LAN, explicitly run `serve --host 0.0.0.0` and set the desktop's LAN address in the client. No external server is required.

## Install a model explicitly

```sh
services/embeddings/.venv/bin/joy-embeddings install-model
services/embeddings/.venv/bin/joy-embeddings serve
```

The default model directory is `~/.local/share/joy/models/minilm`. Choose a different directory with `install-model --path PATH`, then set `JOY_MODEL_PATH=PATH` for `serve`. `JOY_MODEL_THREADS` defaults to `2`.

The chosen model is `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2`, served by fastembed and ONNX Runtime on CPU. It has 384 dimensions, approximately 50 supported languages, and an Apache-2.0 license. The quantized artifact is obtained from `Qdrant/paraphrase-multilingual-MiniLM-L12-v2-onnx-Q` at immutable revision `faf4aa4225822f3bc6376869cb1164e8e3feedd0`.

The installer checks the authoritative Hugging Face file sizes and LFS SHA-256 hashes (or Git blob hashes for small files). It also writes a local SHA-256 manifest. Both the expected and downloaded file totals must be strictly below **1,000,000,000 bytes**. The tested installation totals **266,904,093 bytes**, including tokenizer/configuration files. TLS and artifact verification stay enabled. Failed verification does not produce an install-complete manifest.

On startup, the service verifies every manifest entry and confirms the weights and dimensions match the registered model. Inference is local-only. Long text is split at the model's token window and pooled into a normalized, token-weighted mean, so text after the first 128-token window is included. The returned revision includes the model-file fingerprint and the pooling pipeline version; changing either invalidates existing vectors.

The installer also accepts `--name` for another fastembed model below the size budget and `--revision` for an explicit source revision. This is not a custom-model training or arbitrary model conversion interface. Install into a new directory when changing the model. A model file's disk size and inference RAM are separate budgets; RAM depends on the model, batch, and document lengths.

## HTTP API

The service accepts JSON. Request batches have at most 64 entries and each text at most 30,000 characters. Graphs have at most 1,000 nodes and 4,096 dimensions per vector. Malformed requests return 422; unavailable or invalid embedding output returns 503.

### `GET /health`

```json
{
  "status": "ready",
  "modelLoaded": true,
  "model": {
    "id": "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
    "revision": "<sha256>.chunk-mean-v1",
    "dimensions": 384
  },
  "detail": null
}
```

### `POST /v1/embed`

```json
{"entries": [{"id": "garage", "text": "Garage address\nVehicle repair on Forest Street"}]}
```

```json
{
  "model": {"id": "<model>", "revision": "<revision>", "dimensions": 384},
  "embeddings": [{"id": "garage", "vector": [0.1, 0.2], "textHash": "<sha256>"}]
}
```

The abbreviated vector above illustrates the shape; the real vector has exactly `dimensions` entries. `textHash` is SHA-256 of the exact UTF-8 input, including whitespace and newlines. IDs are returned unchanged and must be unique within a batch. Vectors are finite and nonzero.

The client uses `title + "\n" + description` as its input and persists the model ID, revision, vector, source text, and hash. Recompute after that text or the model/pipeline revision changes. These fields belong in the XLSX snapshot along with the rest of the record data; model weights are installed separately.

### `POST /v1/graph`

```json
{
  "nodes": [
    {"id": "garage", "kind": "knowledge", "title": "Garage address", "vector": [1, 0]},
    {"id": "grigory", "kind": "contact", "title": "Grigory — mechanic", "vector": [0.99, 0.01]}
  ],
  "neighbors": 3,
  "minSimilarity": 0.35
}
```

```json
{
  "nodes": [
    {"id": "garage", "kind": "knowledge", "title": "Garage address", "x": -1, "y": 0},
    {"id": "grigory", "kind": "contact", "title": "Grigory — mechanic", "x": 1, "y": 0}
  ],
  "edges": [{"source": "garage", "target": "grigory", "similarity": 0.999949}]
}
```

`kind` is `knowledge` or `contact`, for the client's two colors. The graph endpoint does not load a model. The client must pass vectors from one model and revision; dimensions and IDs are validated by the service. Edges connect cosine nearest neighbors over `minSimilarity`; their source/target IDs are deterministic and duplicates are removed. Two-dimensional coordinates are a centered PCA projection normalized to fit `[-1, 1]`. Projection approximates high-dimensional proximity; edge scores remain the original cosine similarities. The client handles overlapping labels and isolated nodes.

## Verification

Run the API and file-validation tests from the repository root:

```sh
services/embeddings/.venv/bin/python -m pytest services/embeddings/tests -q
```

The test backend is explicitly synthetic and checks contracts/error handling, not semantic quality. To additionally run the real local model tests after installing it:

```sh
JOY_TEST_MODEL_PATH=/path/to/minilm services/embeddings/.venv/bin/python -m pytest services/embeddings/tests -q
```

The real tests verify the actual model size and manifest, 384-dimensional vectors, a Russian garage/mechanic pair being closer than an unrelated cake recipe, graph linkage, and inclusion of text after the first model window. They do not claim a complete multilingual quality evaluation. Live HTTP health/embed/graph requests have also been exercised against a separately started service.
