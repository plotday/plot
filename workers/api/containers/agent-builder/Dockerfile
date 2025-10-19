# Use Node.js 20 Alpine as base image
FROM node:20-alpine

# Install system dependencies
RUN apk add --no-cache git

# Install Plot SDK globally
RUN npm install -g @plotday/sdk@latest

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
