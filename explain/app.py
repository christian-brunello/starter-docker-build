import os
import re
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from typing import Optional, Dict, Any

from langchain_community.document_loaders import TextLoader, DirectoryLoader
from langchain_text_splitters import RecursiveCharacterTextSplitter
from langchain_community.embeddings import OllamaEmbeddings
from langchain_community.vectorstores import Chroma
from langchain_community.llms import Ollama

app = FastAPI(title="Explain Service - Starter LLM Engine")

DOCS_DIR = "/app/docs"
CHROMA_DIR = "/app/chroma_db"
OLLAMA_URL = "http://127.0.0.1:11434"
DEFAULT_MODEL = "qwen2.5:3b"
DEFAULT_USER_QUERY = "Answer with one Italian sentence only."
MAX_INDEX_BYTES = 20 * 1024

# Curated house notes; skip long manuals / OCR dumps
INDEX_ALLOW = re.compile(
    r"^(site|objects|correlations|chaffolink|thinking|profile|electricity|automation|pv-battery)\.txt$",
    re.I,
)
INDEX_DENY = re.compile(r"(?i)(manuale|pdf\d+|growatt).*")

embeddings = OllamaEmbeddings(base_url=OLLAMA_URL, model="nomic-embed-text")


def get_vectorstore():
    if os.path.exists(CHROMA_DIR) and os.listdir(CHROMA_DIR):
        return Chroma(persist_directory=CHROMA_DIR, embedding_function=embeddings)
    return None


def get_llm(model: Optional[str] = None, num_predict: int = 32, num_ctx: int = 2048):
    return Ollama(
        base_url=OLLAMA_URL,
        model=model or DEFAULT_MODEL,
        temperature=0.2,
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
    try:
        if os.path.getsize(path) > MAX_INDEX_BYTES and not INDEX_ALLOW.match(base):
            return False
    except OSError:
        return False
    if INDEX_ALLOW.match(base):
        return True
    # small curated txt fallback
    return base.lower().endswith(".txt") and os.path.getsize(path) <= MAX_INDEX_BYTES


@app.post("/index")
def index_documents():
    if not os.path.exists(DOCS_DIR) or not os.listdir(DOCS_DIR):
        return {"status": "warning", "message": "Nessun documento statico trovato in rag_docs"}

    loader_txt = DirectoryLoader(DOCS_DIR, glob="**/*.txt", loader_cls=TextLoader)
    docs = []
    for d in loader_txt.load():
        src = d.metadata.get("source") or ""
        if _should_index_file(src):
            docs.append(d)

    if not docs:
        return {"status": "warning", "message": "Nessun contenuto valido (filtro corpus)"}

    text_splitter = RecursiveCharacterTextSplitter(chunk_size=400, chunk_overlap=40)
    split_docs = text_splitter.split_documents(docs)
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
        # RAG for both event and action (k=1); search on TYPE/EVENT/RULE/CONTEXT lines
        vectorstore = get_vectorstore()
        if vectorstore:
            search_bits = []
            for line in starter.splitlines():
                s = line.strip()
                if s.upper().startswith(("EVENT:", "RULE:", "CONTEXT:", "TYPE:")):
                    search_bits.append(s)
            search_q = "\n".join(search_bits) if search_bits else starter
            docs = vectorstore.similarity_search(search_q, k=1)
            if docs:
                static_context = docs[0].page_content.strip()

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

        return {
            "status": "success",
            "explanation": response_text,
            "response": response_text,
        }

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=5001)
