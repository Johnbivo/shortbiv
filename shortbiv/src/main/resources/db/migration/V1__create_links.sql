CREATE TABLE links (
    id BIGINT PRIMARY KEY,
    short_code VARCHAR(7) NOT NULL,
    long_url TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ,
    click_count BIGINT NOT NULL DEFAULT 0
);



-- fast redirect path lookup
CREATE UNIQUE INDEX links_short_code_key ON links (short_code);

-- expiry
CREATE INDEX links_expires_at_idx ON links (expires_at) WHERE expires_at IS NOT NULL;

-- Hands out ids that no two pods can share.
-- START WITH is 62^6, the smallest value that base62-encodes to 7 characters.
-- INCREMENT BY 1000 means one call reserves a block of 1000 the pod serves from memory.
CREATE SEQUENCE link_id_seq START WITH 56800235584 INCREMENT BY 1000;