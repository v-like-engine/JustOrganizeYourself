import hashlib
import json

from fastapi.testclient import TestClient
import pytest

from joy_embeddings.api import create_app
from joy_embeddings.model import LocalModel, file_hash, manifest_revision, verify_model


class TestModel:
    __test__ = False
    loaded = True
    detail = None
    metadata = {"id": "test-model", "revision": "test-revision", "dimensions": 3}

    def embed(self, texts):
        return [[1.0, 0.5, 0.0] for _ in texts]


def test_missing_model_is_reported_without_blocking_graph(tmp_path):
    backend = LocalModel(tmp_path)
    backend.load()
    with TestClient(create_app(backend)) as client:
        health = client.get("/health")
        assert health.status_code == 200
        assert health.json()["modelLoaded"] is False
        assert health.json()["status"] == "model_unavailable"
        response = client.post("/v1/embed", json={"entries": [{"id": "a", "text": "garage"}]})
        assert response.status_code == 503
        assert "install-model" in response.json()["detail"]
        assert client.post("/v1/graph", json={"nodes": []}).json() == {"nodes": [], "edges": []}


def test_embedding_preserves_ids_and_hashes_exact_unicode_text():
    with TestClient(create_app(TestModel())) as client:
        text = "Гараж: мастер Григорий"
        response = client.post("/v1/embed", json={"entries": [{"id": "garage-contact", "text": text}, {"id": "other", "text": "Pharmacy"}]})
        assert response.status_code == 200
        result = response.json()
        assert result["model"] == TestModel.metadata
        assert [entry["id"] for entry in result["embeddings"]] == ["garage-contact", "other"]
        assert result["embeddings"][0]["textHash"] == hashlib.sha256(text.encode()).hexdigest()
        assert len(result["embeddings"][0]["vector"]) == 3


@pytest.mark.parametrize("body", [
    {"entries": []},
    {"entries": [{"id": "a", "text": " "}]},
    {"entries": [{"id": "a", "text": "one"}, {"id": "a", "text": "two"}]},
    {"entries": [{"id": "a", "text": "one", "ignored": "no"}]},
    {"entries": [{"id": str(i), "text": "one"} for i in range(65)]},
])
def test_invalid_embed_requests_are_rejected(body):
    with TestClient(create_app(TestModel())) as client:
        assert client.post("/v1/embed", json=body).status_code == 422


def test_malformed_model_vectors_fail_cleanly():
    class BrokenModel(TestModel):
        def embed(self, texts):
            return [[1.0]]

    with TestClient(create_app(BrokenModel())) as client:
        response = client.post("/v1/embed", json={"entries": [{"id": "a", "text": "one"}]})
        assert response.status_code == 503
        assert "invalid vector" in response.json()["detail"]


def test_graph_neighbors_positions_and_types_without_model(tmp_path):
    nodes = [
        {"id": "garage", "kind": "knowledge", "title": "Garage address", "vector": [1.0, 0.0, 0.0]},
        {"id": "mechanic", "kind": "contact", "title": "Grigory", "vector": [0.99, 0.01, 0.0]},
        {"id": "tea", "kind": "knowledge", "title": "Tea recipe", "vector": [0.0, 0.0, 1.0]},
    ]
    with TestClient(create_app(LocalModel(tmp_path))) as client:
        result = client.post("/v1/graph", json={"nodes": nodes, "neighbors": 1, "minSimilarity": 0.8})
        assert result.status_code == 200
        result = result.json()
        assert len(result["nodes"]) == 3
        assert result["edges"] == [{"source": "garage", "target": "mechanic", "similarity": pytest.approx(0.999949, abs=0.00001)}]
        positions = {node["id"]: (node["x"], node["y"]) for node in result["nodes"]}
        distance = lambda a, b: sum((x-y)**2 for x,y in zip(positions[a], positions[b]))
        assert distance("garage", "mechanic") < distance("garage", "tea")
        assert {node["kind"] for node in result["nodes"]} == {"knowledge", "contact"}


@pytest.mark.parametrize("vectors", [
    [[1, 0], [1, 0, 0]],
    [[0, 0], [1, 0]],
    [[1e308, 1e308], [1, 0]],
])
def test_invalid_graph_vectors_are_rejected(vectors, tmp_path):
    with TestClient(create_app(LocalModel(tmp_path))) as client:
        body = {"nodes": [{"id": str(i), "kind": "knowledge", "title": "x", "vector": vector} for i,vector in enumerate(vectors)]}
        assert client.post("/v1/graph", json=body).status_code == 422


def write_model(tmp_path):
    weights = tmp_path / "model.onnx"
    weights.write_bytes(b"test weights")
    files = {"model.onnx": {"size": weights.stat().st_size, "sha256": file_hash(weights)}}
    manifest = {"id": "test", "dimensions": 3, "modelFile": "model.onnx", "revision": manifest_revision(files), "files": files}
    (tmp_path / "joy-model.json").write_text(json.dumps(manifest))
    return manifest


def test_model_file_mutation_is_rejected(tmp_path):
    write_model(tmp_path)
    assert verify_model(tmp_path)["id"] == "test"
    (tmp_path / "model.onnx").write_bytes(b"changed weight")
    with pytest.raises(ValueError, match="failed verification"):
        verify_model(tmp_path)


def test_manifest_cannot_escape_model_directory(tmp_path):
    manifest = write_model(tmp_path)
    manifest["files"] = {"../outside.onnx": {"size": 0, "sha256": "x"}}
    (tmp_path / "joy-model.json").write_text(json.dumps(manifest))
    with pytest.raises(ValueError, match="outside"):
        verify_model(tmp_path)


def test_unverified_weight_file_is_rejected(tmp_path):
    manifest = write_model(tmp_path)
    other = tmp_path / "unverified.onnx"
    other.write_bytes(b"unverified")
    manifest["modelFile"] = other.name
    (tmp_path / "joy-model.json").write_text(json.dumps(manifest))
    with pytest.raises(ValueError, match="missing"):
        verify_model(tmp_path)


def test_corrupt_model_does_not_prevent_service_start(tmp_path):
    (tmp_path / "joy-model.json").write_text("not json")
    model = LocalModel(tmp_path)
    model.load()
    assert model.loaded is False
    assert "could not be loaded" in model.detail
