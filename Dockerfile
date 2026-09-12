FROM node:20-alpine
WORKDIR /app
COPY package.json ./
COPY server.js ./
COPY lib ./lib
COPY public ./public
# Served by /script/ with the hub URL and key injected, so they must ship.
COPY scripts ./scripts
# Tracked in git on purpose (see .gitignore) so they can be edited straight
# from GitHub instead of through Railway variables. Both are read at boot from
# the working directory: leave one out and the feature goes quiet with no
# error, which is exactly how the Discord relay shipped dead once already.
COPY proxies.txt ./
COPY webhooks.json ./
ENV NODE_ENV=production
EXPOSE 3000
CMD ["node", "server.js"]
