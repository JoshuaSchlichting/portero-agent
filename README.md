# Portero Agent

A lightweight agent that registers a backend with Portero and periodically renews its registration.

## Configuration

Environment variables or CLI flags:
- PORTERO_REGISTER_URL (default: http://127.0.0.1:18080/register)
- PORTERO_SERVICE_NAME (e.g., api.example.com)
- PORTERO_IPV6 (default: ::1)
- PORTERO_PORT
- PORTERO_USE_TLS (default: true)
- PORTERO_TTL_SECONDS (default: 3600)
- PORTERO_REGISTER_SECRET
- PORTERO_JWT_HMAC_KEY
- PORTERO_RENEWAL_FRACTION (default: 0.7)

## Run

cargo run -- \
  --service-name api.example.com \
  --ipv6 ::1 \
  --port 443 \
  --use-tls true \
  --ttl-seconds 3600 \
  --register-secret changeme \
  --jwt-hmac-key changeme

## Notes

- The agent renews its registration before TTL expiry to keep the backend active in Portero’s registry.
- Use short-lived JWTs and secure storage for secrets.
