FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8000

# Policy mounted at /policy/policy.yaml by the Deployment's ConfigMap volume.
ENV POLICY_PATH=/policy/policy.yaml \
    UPSTREAM_URL=http://vllm.inference.svc.cluster.local:8000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
