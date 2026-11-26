# Image dbt du service « dbt » de compose.yaml (profil transfo).
# Le dossier s4/ n'était pas inclus dans le ZIP S4 : image minimale reconstituée,
# versions testées avec ce projet (dbt-core 1.12.7, adaptateur PostgreSQL 1.9.0).
FROM python:3.12-slim-bookworm@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir dbt-core==1.12.7 dbt-postgres==1.9.0
WORKDIR /work
CMD ["dbt", "--version"]
