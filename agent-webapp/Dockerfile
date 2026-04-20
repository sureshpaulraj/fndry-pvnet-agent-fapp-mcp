FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY config.py bot.py tools.py token_cache.py app.py ./

EXPOSE 8080

ENV PORT=8080

CMD ["python", "app.py"]
