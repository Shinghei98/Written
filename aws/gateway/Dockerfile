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

# **The repository layout, preserved.** The first version flattened everything
# beside the package, which meant `gateway_revision` — a hash over paths as well
# as bytes — could not find `aws/gateway/handler.py` where it names it. The fix
# taken then was to teach the checker a second layout and try both; that is a
# checker that agrees with two different trees, which is one more than a pin
# should accept. Keeping the paths identical to the repository means there is
# one layout, and the hash computed in the image is the hash computed in CI.
COPY semantic/src/written_ontology      ${LAMBDA_TASK_ROOT}/semantic/src/written_ontology
COPY semantic/contracts      ${LAMBDA_TASK_ROOT}/semantic/contracts
COPY aws/gateway/*.py      ${LAMBDA_TASK_ROOT}/aws/gateway/

# The flat Lambda modules import each other by bare name and the package is
# imported as `written_ontology`, so both directories are on the path rather
# than the files being moved to suit the importer.
ENV PYTHONPATH="${LAMBDA_TASK_ROOT}/aws/gateway:${LAMBDA_TASK_ROOT}/semantic/src"
ENV WRITTEN_SEMANTIC_CONTRACT="${LAMBDA_TASK_ROOT}/semantic/contracts/compiled_semantic_contract_v1.json"

CMD ["handler.handler"]
