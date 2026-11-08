import os

import numpy as np
import pytest
from fastapi.testclient import TestClient

from joy_embeddings.api import create_app
from joy_embeddings.model import LocalModel, MODEL_LIMIT, verify_model


@pytest.mark.skipif(not os.environ.get("JOY_TEST_MODEL_PATH"), reason="Set JOY_TEST_MODEL_PATH to an explicitly installed model")
def test_verified_local_model_and_russian_semantics():
    path = os.environ["JOY_TEST_MODEL_PATH"]
    model = LocalModel(path)
    manifest = verify_model(model.path)
    assert sum(file["size"] for file in manifest["files"].values()) < MODEL_LIMIT
    model.load()
    assert model.loaded, model.detail
    texts = [
        "Адрес гаража на улице Лесной, 15. Ремонт и обслуживание автомобиля.",
        "Григорий — гаражный мастер, ремонтирует автомобили в гараже на Лесной, 15.",
        "Рецепт шоколадного торта: мука, сахар, масло и какао.",
    ]
    with TestClient(create_app(model)) as client:
        result = client.post("/v1/embed", json={"entries": [{"id": str(i), "text": text} for i,text in enumerate(texts)]})
        assert result.status_code == 200
        vectors = np.array([entry["vector"] for entry in result.json()["embeddings"]])
        assert vectors.shape == (3, 384)
        vectors /= np.linalg.norm(vectors, axis=1)[:, None]
        related, unrelated = float(vectors[0] @ vectors[1]), float(vectors[0] @ vectors[2])
        assert related > unrelated + 0.3
        graph = client.post("/v1/graph", json={"nodes": [
            {"id": str(i), "kind": "contact" if i == 1 else "knowledge", "title": text, "vector": vector.tolist()}
            for i,(text,vector) in enumerate(zip(texts,vectors))
        ], "neighbors": 1, "minSimilarity": 0.35})
        assert graph.status_code == 200
        assert any({edge["source"], edge["target"]} == {"0", "1"} for edge in graph.json()["edges"])


@pytest.mark.skipif(not os.environ.get("JOY_TEST_MODEL_PATH"), reason="Set JOY_TEST_MODEL_PATH to an explicitly installed model")
def test_long_text_uses_more_than_the_first_model_window():
    model = LocalModel(os.environ["JOY_TEST_MODEL_PATH"])
    model.load()
    assert model.loaded, model.detail
    first = "A chocolate cake recipe with flour, cocoa, butter and sugar. " * 40
    second = "Car repair garage and mechanic contact details. " * 40
    vectors = np.asarray(model.embed([first, first + second]))
    assert vectors.shape == (2, 384)
    assert np.linalg.norm(vectors[0] - vectors[1]) > 0.1
