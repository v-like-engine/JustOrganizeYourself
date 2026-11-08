from contextlib import asynccontextmanager
import hashlib
import math
from typing import Literal

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
import numpy as np

from .model import LocalModel


class Entry(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str = Field(min_length=1, max_length=256)
    text: str = Field(min_length=1, max_length=30_000)

    @field_validator("text")
    @classmethod
    def has_text(cls, value):
        if not value.strip():
            raise ValueError("Text is empty")
        return value


class EmbedRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    entries: list[Entry] = Field(min_length=1, max_length=64)

    @model_validator(mode="after")
    def unique_ids(self):
        if len({entry.id for entry in self.entries}) != len(self.entries):
            raise ValueError("Entry IDs must be unique")
        return self


class Node(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str = Field(min_length=1, max_length=256)
    kind: Literal["knowledge", "contact"]
    title: str = Field(max_length=30_000)
    vector: list[float] = Field(min_length=1, max_length=4096)

    @field_validator("vector")
    @classmethod
    def finite_vector(cls, vector):
        if not all(math.isfinite(n) for n in vector) or not any(vector):
            raise ValueError("A vector must contain finite numbers and have nonzero length")
        return vector


class GraphRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    nodes: list[Node] = Field(max_length=1000)
    neighbors: int = Field(default=3, ge=1, le=20)
    minSimilarity: float = Field(default=0.35, ge=-1, le=1)

    @model_validator(mode="after")
    def consistent_nodes(self):
        if len({node.id for node in self.nodes}) != len(self.nodes):
            raise ValueError("Node IDs must be unique")
        if len({len(node.vector) for node in self.nodes}) > 1:
            raise ValueError("All vectors must have the same dimensions and model revision")
        return self


def graph(request):
    if not request.nodes:
        return {"nodes": [], "edges": []}
    matrix = np.asarray([node.vector for node in request.nodes], dtype=np.float64)
    with np.errstate(over="ignore", invalid="ignore"):
        lengths = np.linalg.norm(matrix, axis=1)
    if not np.isfinite(lengths).all() or np.any(lengths == 0):
        raise ValueError("Vector magnitude is not usable")
    matrix /= lengths[:, None]
    scores = np.clip(matrix @ matrix.T, -1, 1)
    edges = {}
    for index, node in enumerate(request.nodes):
        ranked = sorted(
            (other for other in range(len(request.nodes)) if other != index),
            key=lambda other: (-scores[index, other], request.nodes[other].id),
        )
        for other in ranked[:request.neighbors]:
            similarity = float(scores[index, other])
            if similarity < request.minSimilarity:
                continue
            first, second = sorted((node.id, request.nodes[other].id))
            edges[(first, second)] = {"source": first, "target": second, "similarity": similarity}
    centered = matrix - matrix.mean(axis=0)
    points = np.zeros((len(request.nodes), 2))
    if len(request.nodes) > 1:
        u, s, _ = np.linalg.svd(centered, full_matrices=False)
        dimensions = min(2, u.shape[1])
        points[:, :dimensions] = u[:, :dimensions] * s[:dimensions]
        scale = np.abs(points).max()
        if scale:
            points /= scale
    nodes = [
        {"id": node.id, "kind": node.kind, "title": node.title, "x": float(points[i, 0]), "y": float(points[i, 1])}
        for i, node in enumerate(request.nodes)
    ]
    return {"nodes": nodes, "edges": list(edges.values())}


def create_app(model=None):
    backend = model if model is not None else LocalModel()

    @asynccontextmanager
    async def lifespan(app):
        if model is None:
            backend.load()
        yield

    app = FastAPI(title="JOY local embeddings", version="0.1.0", lifespan=lifespan)

    @app.get("/health")
    def health():
        return {
            "status": "ready" if backend.loaded else "model_unavailable",
            "modelLoaded": backend.loaded,
            "model": backend.metadata,
            "detail": backend.detail,
        }

    @app.post("/v1/embed")
    def embed(request: EmbedRequest):
        if not backend.loaded:
            raise HTTPException(503, detail=backend.detail)
        try:
            vectors = backend.embed([entry.text for entry in request.entries])
            if len(vectors) != len(request.entries):
                raise ValueError("Model returned an unexpected number of vectors")
            embeddings = []
            for entry, vector in zip(request.entries, vectors):
                magnitude = math.hypot(*vector)
                if len(vector) != backend.metadata["dimensions"] or not all(math.isfinite(n) for n in vector) or not math.isfinite(magnitude) or magnitude == 0:
                    raise ValueError("Model returned an invalid vector")
                embeddings.append({
                    "id": entry.id,
                    "vector": vector,
                    "textHash": hashlib.sha256(entry.text.encode("utf-8")).hexdigest(),
                })
            return {"model": backend.metadata, "embeddings": embeddings}
        except (RuntimeError, ValueError) as error:
            raise HTTPException(503, detail=f"Embedding calculation failed: {error}") from error

    @app.post("/v1/graph")
    def make_graph(request: GraphRequest):
        try:
            return graph(request)
        except (ValueError, np.linalg.LinAlgError) as error:
            raise HTTPException(422, detail=str(error)) from error

    return app


app = create_app()
