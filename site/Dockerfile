# Build static site from imported www/ sources, serve with nginx.
# Run apply-www.sh before docker build (deploy.sh does this).

FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY import/package.json ./
RUN npm install --no-fund --no-audit
COPY import/ ./
RUN npm run build

FROM nginx:1.27-alpine
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/_site /usr/share/nginx/html
EXPOSE 80
