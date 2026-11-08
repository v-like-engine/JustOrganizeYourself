import math

from fastapi.testclient import TestClient

from joy_embeddings.api import create_app
from joy_embeddings.model import LocalModel


def test_uninstalled_model_starts_and_preserves_core_service_availability(tmp_path, monkeypatch):
    monkeypatch.setenv("JOY_MODEL_PATH", str(tmp_path / "not-installed"))
    with TestClient(create_app()) as client:
        health = client.get("/health")
        assert health.status_code == 200
        assert health.json()["status"] == "model_unavailable"
        assert health.json()["modelLoaded"] is False
        response = client.post("/v1/embed", json={"entries": [{"id": "phone-note", "text": "Address of the garage"}]})
        assert response.status_code == 503
        assert client.post("/v1/graph", json={"nodes": []}).status_code == 200


def test_graph_edges_are_identity_based_and_do_not_depend_on_input_order(tmp_path):
    nodes = [
        {"id": "a", "kind": "knowledge", "title": "Garage address", "vector": [1, 0, 0]},
        {"id": "b", "kind": "contact", "title": "Garage mechanic", "vector": [0.99, 0.01, 0]},
        {"id": "c", "kind": "knowledge", "title": "Different topic", "vector": [0, 0, 1]},
    ]
    with TestClient(create_app(LocalModel(tmp_path))) as client:
        first = client.post("/v1/graph", json={"nodes": nodes, "neighbors": 1, "minSimilarity": 0.9})
        second = client.post("/v1/graph", json={"nodes": list(reversed(nodes)), "neighbors": 1, "minSimilarity": 0.9})
        assert first.status_code == second.status_code == 200
        assert first.json()["edges"] == second.json()["edges"]
        assert {(e["source"], e["target"]) for e in first.json()["edges"]} == {("a", "b")}
        assert all(math.isfinite(n[axis]) for n in first.json()["nodes"] for axis in ("x", "y"))


def test_graph_does_not_accept_same_id_as_two_different_nodes(tmp_path):
    nodes = [
        {"id": "same", "kind": "knowledge", "title": "One", "vector": [1, 0]},
        {"id": "same", "kind": "contact", "title": "Two", "vector": [0, 1]},
    ]
    with TestClient(create_app(LocalModel(tmp_path))) as client:
        assert client.post("/v1/graph", json={"nodes": nodes}).status_code == 422


def test_zero_model_vector_is_rejected_instead_of_saved_as_semantic_data():
    class ZeroModel:
        loaded = True
        detail = None
        metadata = {"id": "broken-model", "revision": "qa", "dimensions": 3}

        def embed(self, texts):
            return [[0.0, 0.0, 0.0] for _ in texts]

    with TestClient(create_app(ZeroModel())) as client:
        response = client.post("/v1/embed", json={"entries": [{"id": "note", "text": "Garage"}]})
        assert response.status_code == 503


def test_mismatched_model_batch_is_rejected_without_partial_vectors():
    class ShortModel:
        loaded = True
        detail = None
        metadata = {"id": "broken-model", "revision": "qa", "dimensions": 2}

        def embed(self, texts):
            return [[1.0, 0.0]]

    with TestClient(create_app(ShortModel())) as client:
        response = client.post("/v1/embed", json={"entries": [{"id": "a", "text": "One"}, {"id": "b", "text": "Two"}]})
        assert response.status_code == 503
        assert "embeddings" not in response.json()
