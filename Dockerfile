# syntax=docker/dockerfile:1

########## Build Stage ##########
FROM node:20-alpine AS build
WORKDIR /app
ENV CI=true

# 의존성 설치 (lock 유무 안전 대응)
COPY package*.json ./
RUN npm ci --no-audit --no-fund || npm install --no-audit --no-fund

# 소스 복사 및 빌드
COPY . .
# 상대경로 빌드(경로 비의존) - 필요 시 build-arg로 override 가능
ARG PUBLIC_URL=.
ENV PUBLIC_URL=${PUBLIC_URL}
RUN npm run build

########## Runtime Stage ##########
FROM nginx:1.27-alpine

# Nginx를 3000 포트에서 수신하도록 구성
RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/default.conf

# 빌드 산출물 배치
COPY --from=build /app/build /usr/share/nginx/html

EXPOSE 3000

# 헬스체크(로컬용; K8s 프로브는 기존 그대로)
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://127.0.0.1:3000/ >/dev/null || exit 1
