# Use the official Elixir image as the base
FROM elixir:1.14-alpine

# Set environment variables
ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    HOME=/app

# Install system dependencies
RUN apk add --no-cache \
    build-base \
    git \
    nodejs \
    npm \
    postgresql-client \
    python3 \
    make \
    gcc \
    libc-dev \
    openssl-dev

# Set work directory
WORKDIR /app

# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files
COPY mix.exs mix.lock ./

# Install production dependencies
RUN mix deps.get --only prod && \
    mix deps.compile

# Copy assets
COPY assets/package.json assets/package-lock.json ./assets/
COPY assets ./assets

# Install node dependencies and build assets
RUN cd assets && npm install && cd ..

# Copy source code
COPY . .

# Build assets
RUN mix assets.deploy

# Compile the application
RUN mix compile

# Build the release
RUN mix release

# Runtime stage
FROM alpine:3.18

# Install runtime dependencies
RUN apk add --no-cache \
    openssl \
    ncurses-libs \
    postgresql-client \
    ca-certificates

# Set environment variables
ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    HOME=/app

# Set work directory
WORKDIR /app

# Copy the release from build stage
COPY --from=0 /app/_build/prod/rel/jump_agent ./

# Create user for running the application
RUN addgroup -g 1001 -S elixir && \
    adduser -S elixir -u 1001 -G elixir

# Change ownership of the app directory
RUN chown -R elixir:elixir /app

# Switch to non-root user
USER elixir

# Expose port
EXPOSE 4000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD ["./bin/jump_agent", "rpc", "JumpAgent.HealthCheck.check()"]

# Default command
CMD ["./bin/jump_agent", "start"]