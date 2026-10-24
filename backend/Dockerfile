# 注意：本仓库开发机未安装 Docker，此文件尚未经过实测。
FROM python:3.11-slim
WORKDIR /app
ARG PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
COPY requirements.txt .
RUN pip install --no-cache-dir -i ${PIP_INDEX_URL} -r requirements.txt
COPY app ./app
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
