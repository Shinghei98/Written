# The gateway image. It carries no model and no weights: vLLM is a separate
# image behind `WRITTEN_MODEL_ENDPOINT`, and keeping them apart is what lets the
# deployment manifest name two digests rather than one.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

WORKDIR /srv
COPY aws/gateway/requirements.txt /srv/requirements.txt
RUN pip install --no-cache-dir -r /srv/requirements.txt

# The contract and its schemas travel with the gateway, because the gateway
# attests what it loaded and cannot attest a file it fetches at runtime.
COPY semantic/src/written_ontology /srv/written_ontology
COPY semantic/contracts /srv/semantic/contracts
COPY aws/gateway/server.py aws/gateway/manifest.py /srv/

ENV PYTHONPATH=/srv \
    WRITTEN_SEMANTIC_CONTRACT=/srv/semantic/contracts/compiled_semantic_contract_v1.json
EXPOSE 8080

# No request logging. The default access log of every server prints the path and
# often the body, and §20.1 is why `model_invocation_items` has no text column.
CMD ["python", "/srv/server.py"]
