"""Exercise a real OIDC authorization-code + S256 PKCE login against CI Keycloak."""
import base64
import hashlib
import html
import os
import secrets
from html.parser import HTMLParser
from urllib.parse import parse_qs, urlencode, urljoin, urlparse

import jwt
import requests

BASE = os.environ.get("OIDC_TEST_BASE", "http://127.0.0.1:8080").rstrip("/")
ADMIN_PASSWORD = os.environ["KC_BOOTSTRAP_ADMIN_PASSWORD"]
REALM = "ci-smoke"
CLIENT_ID = "ci-pkce-client"
REDIRECT = "http://127.0.0.1:8765/callback"
USERNAME = "ci-user"
PASSWORD = "ci-user-password-only-for-test"


class LoginForm(HTMLParser):
    def __init__(self):
        super().__init__()
        self.action = None
        self.hidden = {}
        self.in_form = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "form" and attrs.get("id") == "kc-form-login":
            self.in_form = True
            self.action = html.unescape(attrs["action"])
        elif self.in_form and tag == "input" and attrs.get("type") == "hidden":
            self.hidden[attrs["name"]] = attrs.get("value", "")

    def handle_endtag(self, tag):
        if tag == "form":
            self.in_form = False


def post_json(session, path, payload, token):
    response = session.post(
        BASE + path,
        json=payload,
        headers={"Authorization": f"Bearer {token}"},
        timeout=15,
    )
    response.raise_for_status()


def main():
    session = requests.Session()
    admin_response = session.post(
        BASE + "/realms/master/protocol/openid-connect/token",
        data={
            "grant_type": "password",
            "client_id": "admin-cli",
            "username": os.environ.get("KC_BOOTSTRAP_ADMIN_USERNAME", "admin"),
            "password": ADMIN_PASSWORD,
        },
        timeout=15,
    )
    admin_response.raise_for_status()
    admin_token = admin_response.json()["access_token"]
    post_json(session, "/admin/realms", {"realm": REALM, "enabled": True}, admin_token)
    post_json(
        session,
        f"/admin/realms/{REALM}/users",
        {
            "username": USERNAME,
            "enabled": True,
            "emailVerified": True,
            "credentials": [{"type": "password", "value": PASSWORD, "temporary": False}],
        },
        admin_token,
    )
    post_json(
        session,
        f"/admin/realms/{REALM}/clients",
        {
            "clientId": CLIENT_ID,
            "protocol": "openid-connect",
            "enabled": True,
            "publicClient": True,
            "standardFlowEnabled": True,
            "implicitFlowEnabled": False,
            "directAccessGrantsEnabled": False,
            "redirectUris": [REDIRECT],
            "webOrigins": [],
            "attributes": {"pkce.code.challenge.method": "S256"},
        },
        admin_token,
    )

    issuer = BASE + f"/realms/{REALM}"
    discovery_response = session.get(issuer + "/.well-known/openid-configuration", timeout=15)
    discovery_response.raise_for_status()
    discovery = discovery_response.json()
    assert discovery["issuer"] == issuer

    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(24)
    nonce = secrets.token_urlsafe(24)
    authorize_url = discovery["authorization_endpoint"] + "?" + urlencode(
        {
            "client_id": CLIENT_ID,
            "redirect_uri": REDIRECT,
            "response_type": "code",
            "scope": "openid profile email",
            "state": state,
            "nonce": nonce,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        }
    )
    login_page = session.get(authorize_url, timeout=15)
    login_page.raise_for_status()
    form = LoginForm()
    form.feed(login_page.text)
    assert form.action, "Keycloak login form not found"
    response = session.post(
        form.action,
        data={**form.hidden, "username": USERNAME, "password": PASSWORD},
        allow_redirects=False,
        timeout=15,
    )
    if response.status_code not in (302, 303):
        class VisibleText(HTMLParser):
            def __init__(self):
                super().__init__()
                self.parts = []

            def handle_data(self, data):
                if data.strip():
                    self.parts.append(data.strip())

        visible = VisibleText()
        visible.feed(response.text)
        raise AssertionError(
            f"Login failed: {response.status_code}, path={urlparse(response.url).path}, "
            f"message={' '.join(visible.parts)[:500]}"
        )
    location = response.headers["Location"]
    assert location.startswith(REDIRECT + "?"), f"Unexpected redirect: {location}"
    params = parse_qs(urlparse(location).query)
    assert params["state"] == [state]
    assert "code" in params and "error" not in params

    token_response = session.post(
        discovery["token_endpoint"],
        data={
            "grant_type": "authorization_code",
            "client_id": CLIENT_ID,
            "redirect_uri": REDIRECT,
            "code": params["code"][0],
            "code_verifier": verifier,
        },
        timeout=15,
    )
    token_response.raise_for_status()
    tokens = token_response.json()
    key = jwt.PyJWKClient(discovery["jwks_uri"]).get_signing_key_from_jwt(tokens["id_token"]).key
    claims = jwt.decode(
        tokens["id_token"],
        key,
        algorithms=["RS256"],
        audience=CLIENT_ID,
        issuer=issuer,
    )
    assert claims["nonce"] == nonce
    userinfo_response = session.get(
        discovery["userinfo_endpoint"],
        headers={"Authorization": f"Bearer {tokens['access_token']}"},
        timeout=15,
    )
    userinfo_response.raise_for_status()
    assert userinfo_response.json()["sub"] == claims["sub"]
    print("OIDC authorization code + PKCE, ID token and userinfo verified")


if __name__ == "__main__":
    main()
