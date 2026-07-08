# Use Node.js 22 Alpine as base image (current LTS)
FROM node:22-alpine

# Install system dependencies
RUN apk add --no-cache git

# Install Plot SDK globally
RUN npm install -g @plotday/twister@latest

# tsc for in-loop typechecking; pinned to match the server's devDependency major
RUN npm install -g typescript@5.8.3

# Version-keyed dependency templates (populated at runtime)
RUN mkdir -p /templates

# Set working directory for the server
WORKDIR /app

# Copy server package files
COPY server/package.json server/package-lock.json* ./

# Install server dependencies
RUN npm install

# Copy server source code
COPY server/tsconfig.json ./
COPY server/src ./src

# Build the TypeScript server
RUN npm run build

# Expose the server port
EXPOSE 3000

# Start the server
CMD ["node", "build/server.js"]
