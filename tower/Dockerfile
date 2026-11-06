# Python 3.14, not 3.15: PyYAML 6.0.3 has no musl wheel for 3.15, and this base has no compiler.
FROM python:3.14.7-alpine3.24
COPY --from=ghcr.io/astral-sh/uv:0.13.5 /uv /usr/local/bin/uv

ENV UV_PYTHON_DOWNLOADS=never UV_LINK_MODE=copy PYTHONUNBUFFERED=1
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY tower ./tower

RUN adduser -D -u 10001 tower && mkdir /data && chown tower /data
USER tower
ENV PATH="/app/.venv/bin:$PATH"
EXPOSE 8000
CMD ["uvicorn", "--factory", "tower.app:main", "--host", "0.0.0.0", "--port", "8000"]
