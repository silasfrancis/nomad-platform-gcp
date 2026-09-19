"""
nomad_client.py
Single shared requests.Session for all Nomad API calls.

`requests`/urllib3 do NOT auto-read NOMAD_CACERT, NOMAD_CLIENT_CERT,
NOMAD_CLIENT_KEY, or NOMAD_TLS_SERVER_NAME the way the Go-based Nomad/Consul/
Vault CLIs and SDKs do. Every module that talks to the Nomad API must go
through get_session() here rather than calling `requests` directly, or it
silently falls back to the system CA bundle and exact-hostname verification —
which fails whenever NOMAD_ADDR is a bare IP (e.g. resolved via Consul
service discovery) rather than the DNS name the server cert was issued for.
"""

import requests
from requests.adapters import HTTPAdapter

from config import (
    NOMAD_CACERT,
    NOMAD_CLIENT_CERT,
    NOMAD_CLIENT_KEY,
    NOMAD_TLS_SERVER_NAME,
)


class _TLSServerNameAdapter(HTTPAdapter):
    """
    Verifies the server certificate against a hostname different from the
    one actually dialed — the requests/urllib3 equivalent of the Go SDKs'
    NOMAD_TLS_SERVER_NAME override, via urllib3's `assert_hostname`.
    """

    def __init__(self, server_hostname: str, **kwargs):
        self._server_hostname = server_hostname
        super().__init__(**kwargs)

    def init_poolmanager(self, *args, **kwargs):
        kwargs["assert_hostname"] = self._server_hostname
        return super().init_poolmanager(*args, **kwargs)

    def proxy_manager_for(self, *args, **kwargs):
        kwargs["assert_hostname"] = self._server_hostname
        return super().proxy_manager_for(*args, **kwargs)

    def cert_verify(self, conn, url, verify, cert):
        super().cert_verify(conn, url, verify, cert)
        conn.assert_hostname = self._server_hostname


def _build_session() -> requests.Session:
    session = requests.Session()

    # CA trust: NOMAD_CACERT if set, else fall back to requests' default
    # (certifi) trust store.
    session.verify = NOMAD_CACERT or True

    # Optional mTLS client identity.
    if NOMAD_CLIENT_CERT and NOMAD_CLIENT_KEY:
        session.cert = (NOMAD_CLIENT_CERT, NOMAD_CLIENT_KEY)

    # Hostname override for cert verification, when NOMAD_ADDR is an IP.
    if NOMAD_TLS_SERVER_NAME:
        adapter = _TLSServerNameAdapter(NOMAD_TLS_SERVER_NAME)
        session.mount("https://", adapter)

    return session


# Built once at import time and shared across detector/remediator/summarizer.
session = _build_session()
