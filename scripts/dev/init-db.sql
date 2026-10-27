-- Used only by the fresh, loopback-bound development container in compose.yaml.
-- Canonical roles are required by the migrations even before runtime activation.
-- These local passwords must never be used for a hosted installation.
CREATE ROLE maraithon_object_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE maraithon_migrator LOGIN PASSWORD 'maraithon-local-only' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE maraithon_runtime LOGIN PASSWORD 'maraithon-local-only' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE maraithon_payload_verifier LOGIN PASSWORD 'maraithon-local-only' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE maraithon_incident_operator LOGIN PASSWORD 'maraithon-local-only' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE maraithon_activation_operator LOGIN PASSWORD 'maraithon-local-only' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;

GRANT maraithon_object_owner TO maraithon_migrator;
GRANT USAGE, CREATE ON SCHEMA public TO maraithon_object_owner, maraithon_migrator;
SELECT format('ALTER DATABASE %I OWNER TO maraithon_migrator', current_database()) \gexec

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
