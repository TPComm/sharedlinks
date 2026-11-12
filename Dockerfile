FROM python:3.13-slim
WORKDIR /app
COPY server.py ./
COPY static ./static
ENV PORT=8000 DATA_DIR=/data PYTHONUNBUFFERED=1
VOLUME /data
EXPOSE 8000
CMD ["python3", "server.py"]
