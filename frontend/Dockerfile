# ============================================================
# STAGE 1: Build
# ============================================================
FROM node:18-alpine AS builder

WORKDIR /build

COPY index.html app.js ./

RUN ls -la && echo "Assets OK"

# ============================================================
# STAGE 2: Runtime Nginx
# ============================================================
FROM nginx:alpine AS runtime

RUN rm -rf /usr/share/nginx/html/*

COPY --from=builder /build/index.html /usr/share/nginx/html/
COPY --from=builder /build/app.js /usr/share/nginx/html/
COPY default.conf /etc/nginx/conf.d/default.conf

RUN chown -R nginx:nginx /usr/share/nginx/html && \
    chown -R nginx:nginx /var/cache/nginx && \
    chown -R nginx:nginx /var/log/nginx && \
    touch /var/run/nginx.pid && \
    chown nginx:nginx /var/run/nginx.pid

USER nginx

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]