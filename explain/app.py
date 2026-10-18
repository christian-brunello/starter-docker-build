import argparse
import os
import re
import shutil
from datetime import datetime, timezone
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from typing import Optional, Dict, Any, List, Tuple

from langchain_community.document_loaders import TextLoader, DirectoryLoader
from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_community.embeddings import OllamaEmbeddings
from langchain_community.vectorstores import Chroma
from langchain_community.llms import Ollama

try:
    from langchain_core.documents import Document
except ImportError:  # langchain 0.1.x
    from langchain.schema import Document

app = FastAPI(title="Explain Service - Starter LLM Engine")

DOCS_DIR = "/app/docs"
CHROMA_DIR = "/app/chroma_db"
OLLAMA_URL = "http://127.0.0.1:11434"
DEFAULT_MODEL = "qwen2.5:7b"
# Style/instructions come from the client system prompt; keep this neutral.
DEFAULT_USER_QUERY = "Answer with one Italian sentence only."
MAX_INDEX_BYTES = 100 * 1024
RETRIEVE_K = 4

# Optional append log: --log-text PATH or EXPLAIN_LOG_TEXT (same idea as starter-explain).
LOG_TEXT_PATH: Optional[str] = os.environ.get("EXPLAIN_LOG_TEXT") or None

# Skip obvious dumps; otherwise index curated .txt/.md under the size cap.
INDEX_DENY = re.compile(r"(?i)(manuale|pdf\d+|growatt).*")
# Tokens useful for heading alignment (Service:datapoint, paths, ids) — not domain-specific.
HEADING_TOKEN_RE = re.compile(r"[A-Za-z][A-Za-z0-9_.-]{1,80}(?::[A-Za-z0-9_.-]{1,80})?")

embeddings = OllamaEmbeddings(base_url=OLLAMA_URL, model="nomic-embed-text")


def get_vectorstore():
    if os.path.exists(CHROMA_DIR) and os.listdir(CHROMA_DIR):
        return Chroma(persist_directory=CHROMA_DIR, embedding_function=embeddings)
    return None


def get_llm(model: Optional[str] = None, num_predict: int = 32, num_ctx: int = 2048):
    return Ollama(
        base_url=OLLAMA_URL,
        model=model or DEFAULT_MODEL,
        temperature=0.1,
        num_predict=num_predict,
        num_ctx=num_ctx,
    )


class ExplainPayload(BaseModel):
    prompt: Optional[str] = None
    system: Optional[str] = None
    model: Optional[str] = None
    stream: Optional[bool] = False
    keep_alive: Optional[Any] = None
    options: Optional[Dict[str, Any]] = None
    starter_prompt: Optional[str] = None
    user_query: Optional[str] = Field(default=None)


def _should_index_file(path: str) -> bool:
    base = os.path.basename(path)
    if INDEX_DENY.search(base):
        return False
    if "manuals" in path.replace("\\", "/").split("/"):
        return False
    lower = base.lower()
    if not (lower.endswith(".txt") or lower.endswith(".md")):
        return False
    try:
        return os.path.getsize(path) <= MAX_INDEX_BYTES
    except OSError:
        return False


def _clear_chroma_dir() -> None:
    """Empty persist dir without removing the mount point."""
    if not os.path.isdir(CHROMA_DIR):
        os.makedirs(CHROMA_DIR, exist_ok=True)
        return
    for name in os.listdir(CHROMA_DIR):
        path = os.path.join(CHROMA_DIR, name)
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            try:
                os.unlink(path)
            except IsADirectoryError:
                shutil.rmtree(path)


def _split_documents(docs: List[Document]) -> List[Document]:
    """
    Keep markdown ## sections intact when present (generic catalog/docs layout).
    Fall back to recursive split for prose without headings.
    """
    out: List[Document] = []
    prose: List[Document] = []
    for d in docs:
        text = d.page_content or ""
        if re.search(r"(?m)^## ", text):
            for part in re.split(r"(?m)(?=^## )", text):
                chunk = part.strip()
                if not chunk:
                    continue
                meta = dict(d.metadata or {})
                if chunk.startswith("## "):
                    meta["heading"] = chunk.splitlines()[0][3:].strip()
                out.append(Document(page_content=chunk, metadata=meta))
        else:
            prose.append(d)
    if prose:
        splitter = RecursiveCharacterTextSplitter(
            chunk_size=500,
            chunk_overlap=50,
            separators=["\n\n", "\n", " ", ""],
        )
        out.extend(splitter.split_documents(prose))
    return out


def _search_query(starter: str) -> str:
    """Prefer structured prompt lines when present; else full prompt."""
    bits = []
    for line in starter.splitlines():
        s = line.strip()
        if s.upper().startswith(("EVENT:", "RULE:", "CONTEXT:", "TYPE:")):
            bits.append(s)
    return "\n".join(bits) if bits else starter


def _prompt_tokens(starter: str) -> List[str]:
    return [t for t in HEADING_TOKEN_RE.findall(starter) if len(t) >= 3]


def _chunk_heading(text: str, metadata: Optional[dict]) -> str:
    if metadata and metadata.get("heading"):
        return str(metadata["heading"]).strip()
    first = (text or "").splitlines()[0].strip() if text else ""
    if first.startswith("## "):
        return first[3:].strip()
    return ""


def _pick_doc(
    hits: List[Tuple[Document, float]], starter: str
) -> Tuple[str, Optional[float], str]:
    """
    Choose one chunk: prefer a ## heading that appears as a token in the prompt
    (generic catalog alignment). Else take the best similarity hit.
    Distance scales differ by Chroma metric — never use a fixed absolute cutoff.
    """
    if not hits:
        return "", None, ""
    tokens = {t.casefold() for t in _prompt_tokens(starter)}
    for doc, dist in hits:
        text = (doc.page_content or "").strip()
        heading = _chunk_heading(text, doc.metadata)
        if heading and heading.casefold() in tokens:
            return text, dist, heading
    # Also scan all hits for heading∩prompt even if not rank-1 by embedding
    for doc, dist in hits:
        text = (doc.page_content or "").strip()
        heading = _chunk_heading(text, doc.metadata)
        if not heading:
            continue
        # Partial: heading contained in prompt text (covers "EVENT: Foo:bar …")
        if heading in starter or heading.casefold() in starter.casefold():
            return text, dist, heading
    best_doc, best_dist = hits[0]
    text = (best_doc.page_content or "").strip()
    return text, best_dist, _chunk_heading(text, best_doc.metadata)


def _append_text_log(received: str, llm_prompt: str, response: str) -> None:
    """Append one iteration: timestamp, received prompt, RAG-enriched LLM prompt, response."""
    path = LOG_TEXT_PATH
    if not path:
        return
    try:
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        ts = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
        with open(path, "a", encoding="utf-8") as fp:
            fp.write(f"{ts}\n")
            fp.write("received:\n")
            fp.write(f"{received if received else '(empty)'}\n")
            fp.write("llm_prompt:\n")
            fp.write(f"{llm_prompt if llm_prompt else '(empty)'}\n")
            fp.write(f"response: {response if response else ''}\n")
            fp.write("\n")
            fp.flush()
    except OSError as exc:
        # Never fail the request because of logging.
        print(f"WARNING: cannot append to --log-text {path}: {exc}", flush=True)


@app.post("/index")
def index_documents():
    if not os.path.exists(DOCS_DIR) or not os.listdir(DOCS_DIR):
        return {"status": "warning", "message": "Nessun documento statico trovato in rag_docs"}

    docs = []
    for glob_pat in ("**/*.txt", "**/*.md"):
        loader = DirectoryLoader(DOCS_DIR, glob=glob_pat, loader_cls=TextLoader)
        for d in loader.load():
            src = d.metadata.get("source") or ""
            if _should_index_file(src):
                docs.append(d)

    if not docs:
        return {"status": "warning", "message": "Nessun contenuto valido (filtro corpus)"}

    split_docs = _split_documents(docs)
    if not split_docs:
        return {"status": "warning", "message": "Nessun chunk da indicizzare"}

    _clear_chroma_dir()
    vectorstore = Chroma.from_documents(
        documents=split_docs,
        embedding=embeddings,
        persist_directory=CHROMA_DIR,
    )
    vectorstore.persist()
    return {"status": "success", "indexed_chunks": len(split_docs), "docs": len(docs)}


@app.post("/explain")
def explain_event(payload: ExplainPayload):
    try:
        starter = (payload.prompt or payload.starter_prompt or "").strip()
        if not starter:
            raise HTTPException(status_code=422, detail="prompt or starter_prompt is required")

        system = (payload.system or "").strip()
        user_query = (payload.user_query or DEFAULT_USER_QUERY).strip()

        num_predict = 32
        num_ctx = 2048
        if payload.options and isinstance(payload.options, dict):
            try:
                num_predict = int(payload.options.get("num_predict", num_predict))
            except (TypeError, ValueError):
                pass
            try:
                num_ctx = int(payload.options.get("num_ctx", num_ctx))
            except (TypeError, ValueError):
                pass

        static_context = ""
        doc_distance = None
        doc_heading = ""
        vectorstore = get_vectorstore()
        if vectorstore:
            search_q = _search_query(starter)
            hits: List[Tuple[Document, float]] = []
            # Prefer exact metadata heading when prompt contains catalog-like tokens
            # (e.g. "## Name" sections). Generic: any Token:subtoken in the prompt.
            for tok in _prompt_tokens(starter):
                if ":" not in tok:
                    continue
                try:
                    keyed = vectorstore.similarity_search_with_score(
                        tok, k=1, filter={"heading": tok}
                    )
                except Exception:
                    keyed = []
                if keyed:
                    hits = keyed
                    break
            if not hits:
                try:
                    hits = vectorstore.similarity_search_with_score(
                        search_q, k=RETRIEVE_K
                    )
                except Exception:
                    plain = vectorstore.similarity_search(search_q, k=RETRIEVE_K)
                    hits = [(d, 0.0) for d in plain]
            static_context, doc_distance, doc_heading = _pick_doc(hits, starter)

        if system:
            full_prompt = f"{system}\n\n{starter}\n"
        else:
            full_prompt = f"{starter}\n"

        if static_context:
            full_prompt += f"\n[DOC]\n{static_context}\n"

        full_prompt += f"\n{user_query}\n"

        llm = get_llm(payload.model, num_predict=num_predict, num_ctx=num_ctx)
        response_text = llm.invoke(full_prompt)
        if isinstance(response_text, str):
            response_text = response_text.strip().splitlines()[0].strip()
            for pref in ("ACTION:", "EVENT:", "TYPE:", "[DOC]", "DOC:"):
                u = response_text.upper()
                pu = pref.upper()
                if u.startswith(pu):
                    response_text = response_text[len(pref):].strip()

        # Log received client prompt (system + starter) vs RAG-enriched LLM prompt.
        received_log = starter
        if system:
            received_log = f"system:\n{system}\n\nprompt:\n{starter}"
        _append_text_log(received_log, full_prompt, response_text)

        return {
            "status": "success",
            "explanation": response_text,
            "response": response_text,
            "doc_heading": doc_heading or None,
            "doc_distance": doc_distance,
            "doc_used": bool(static_context),
        }

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


def _parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Explain Service - Starter LLM Engine")
    p.add_argument(
        "--log-text",
        metavar="FILE",
        default=os.environ.get("EXPLAIN_LOG_TEXT") or None,
        help="Append each /explain iteration (timestamp, received, llm_prompt, response) to FILE",
    )
    p.add_argument("--host", default="0.0.0.0", help="Bind host (default 0.0.0.0)")
    p.add_argument("--port", type=int, default=5001, help="Bind port (default 5001)")
    return p.parse_args(argv)


if __name__ == "__main__":
    import uvicorn

    args = _parse_args()
    LOG_TEXT_PATH = args.log_text
    if LOG_TEXT_PATH:
        parent = os.path.dirname(LOG_TEXT_PATH)
        if parent:
            os.makedirs(parent, exist_ok=True)
        print(f"log_text={LOG_TEXT_PATH}", flush=True)
    else:
        print("log_text=(none)", flush=True)

    uvicorn.run(app, host=args.host, port=args.port)
