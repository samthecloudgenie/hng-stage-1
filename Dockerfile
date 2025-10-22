# Use a small official Python image
FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Copy project files
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Expose the internal app port
EXPOSE 5000

# Run the app
CMD ["python", "app.py"]
