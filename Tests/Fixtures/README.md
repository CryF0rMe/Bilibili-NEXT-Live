These JSON fixtures are reduced unauthenticated public Bilibili live API captures
from 2026-11-07. They retain response envelopes, list keys, pagination metadata,
and the room/category fields used by the app. Tracking callbacks, session IDs,
ad metadata, and unrelated fields were removed. The area fixture keeps two
children per parent to cover string IDs without copying the entire area index.

They are consumed only by the standalone CI contract tests, never by the app's
discovery service. Runtime recommendations always come from public live APIs.
