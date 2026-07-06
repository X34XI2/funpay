FROM python:3.11-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for better caching
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Create necessary directories
RUN mkdir -p configs logs storage/cache storage/plugins storage/products plugins

# Create empty config files if they don't exist
RUN touch configs/auto_delivery.cfg configs/auto_response.cfg

# Set environment variable for non-interactive mode
ENV PYTHONUNBUFFERED=1

# Run the application
CMD ["python", "main.py"]
