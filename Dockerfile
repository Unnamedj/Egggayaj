FROM node:20-alpine
WORKDIR /app
COPY package.json ./
COPY server.js ./
COPY lib ./lib
COPY public ./public
# Served by /script/ with the hub URL and key injected, so they must ship.
COPY scripts ./scripts
# Tracked in git on purpose (see .gitignore) so it can be edited straight from
# GitHub instead of through a Railway variable.
COPY proxies.txt ./
ENV NODE_ENV=production
EXPOSE 3000
CMD ["node", "server.js"]
