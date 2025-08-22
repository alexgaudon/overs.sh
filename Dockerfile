# Build stage
FROM golang:1.20-alpine AS builder

WORKDIR /app

# Install dependencies
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build the application
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o bin/overssh cmd/main.go

# Final stage
FROM alpine:latest

# Install ca-certificates, openssh for SSH host key generation, and wget for health checks
RUN apk --no-cache add ca-certificates openssh wget

WORKDIR /root/

# Copy the binary from builder stage
COPY --from=builder /app/bin/overssh .

# Copy public directory for static files
COPY --from=builder /app/public ./public

# Expose SSH port (typically 22) and HTTP port (check your server code for actual port)
EXPOSE 22 8080

# Generate SSH host key if it doesn't exist (fallback for local dev), then run the binary
CMD ["sh", "-c", "[ -f ./key ] || ssh-keygen -f ./key -t rsa -N '' && ./overssh"]