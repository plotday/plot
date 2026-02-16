FROM pgvector/pgvector:pg18

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      postgresql-18-pgtap \
      postgresql-18-plpgsql-check && \
    rm -rf /var/lib/apt/lists/*
