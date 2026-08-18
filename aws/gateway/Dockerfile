# The gateway, as a Lambda container image.
#
# It carries no model and no weights: Qwen is a SageMaker asynchronous endpoint
# behind `WRITTEN_SAGEMAKER_ENDPOINT`, and keeping them apart is what lets the
# deployment manifest name two image digests rather than one.
#
# The AWS base image carries boto3, so `sagemaker_transport` imports it without
# this layer pinning a copy that then drifts from the one AWS patches — the same
# reasoning `aws/worker/build.sh` gives for leaving it out of the zip.
FROM public.ecr.aws/lambda/python:3.12

COPY aws/gateway/requirements.txt ${LAMBDA_TASK_ROOT}/requirements.txt
RUN pip install --no-cache-dir -r ${LAMBDA_TASK_ROOT}/requirements.txt

# The contract and its schemas travel with the image, because the gateway
# attests what it loaded and cannot attest a file it fetches at runtime.
COPY semantic/src/written_ontology ${LAMBDA_TASK_ROOT}/written_ontology
COPY semantic/contracts ${LAMBDA_TASK_ROOT}/semantic/contracts
COPY aws/gateway/handler.py aws/gateway/server.py aws/gateway/manifest.py \
     aws/gateway/sagemaker_transport.py ${LAMBDA_TASK_ROOT}/

ENV WRITTEN_SEMANTIC_CONTRACT=${LAMBDA_TASK_ROOT}/semantic/contracts/compiled_semantic_contract_v1.json

CMD ["handler.handler"]
