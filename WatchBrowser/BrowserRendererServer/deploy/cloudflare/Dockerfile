FROM mcr.microsoft.com/playwright/python:v1.58.0-noble

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    WATCHBROWSER_CHROMIUM_EGRESS_ACK=disabled \
    BROWSER_RENDERER_CHROMIUM_EGRESS_ISOLATED=false

WORKDIR /srv/watch-browser-renderer

COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY --chown=pwuser:pwuser app ./app
COPY --chmod=0555 --chown=pwuser:pwuser \
    deploy/cloudflare/container-start.sh \
    /usr/local/bin/watchbrowser-container-start

USER pwuser
EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/watchbrowser-container-start"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
