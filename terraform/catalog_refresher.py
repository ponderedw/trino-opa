#!/usr/bin/env python3
"""
Catalog refresher for Trino.

Modes:
  --init   Render catalog templates to CATALOG_DIR and exit (runs as init container).
  default  Watch credentials for changes; when detected, wait for idle cluster, then
           trigger a rolling restart so the init container reruns with fresh credentials.
"""

import os
import re
import ssl
import sys
import time
import hashlib
import json
import datetime
import urllib.request
import urllib.error
import base64
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

CREDENTIALS_DIR = "/etc/trino/credentials"
TEMPLATES_DIR   = "/etc/trino/catalog-templates"
CATALOG_DIR     = "/etc/trino/catalog"
TRINO_URL       = os.environ.get("TRINO_URL", "http://localhost:8080")
CHECK_INTERVAL  = 30

_K8S_HOST = os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc")
_K8S_PORT = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
K8S_API   = "https://{}:{}".format(_K8S_HOST, _K8S_PORT)
SA_TOKEN  = "/var/run/secrets/kubernetes.io/serviceaccount/token"
SA_CA     = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
SA_NS     = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"


# ---------------------------------------------------------------------------
# Credentials / templates
# ---------------------------------------------------------------------------

def read_credentials():
    creds = {}
    if not os.path.exists(CREDENTIALS_DIR):
        return creds
    for filename in os.listdir(CREDENTIALS_DIR):
        filepath = os.path.join(CREDENTIALS_DIR, filename)
        if os.path.isfile(filepath):
            try:
                with open(filepath) as f:
                    creds[filename] = f.read().strip()
            except Exception as e:
                log.warning("Failed to read %s: %s", filepath, e)
    return creds


def read_templates():
    templates = {}
    if not os.path.exists(TEMPLATES_DIR):
        return templates
    for filename in os.listdir(TEMPLATES_DIR):
        if filename.endswith(".properties.tmpl"):
            catalog_name = filename[: -len(".properties.tmpl")]
            filepath = os.path.join(TEMPLATES_DIR, filename)
            with open(filepath) as f:
                templates[catalog_name] = f.read()
    return templates


def render_template(template, creds):
    missing = []

    def replace(match):
        key = match.group(1)
        if key not in creds:
            missing.append(key)
            return match.group(0)
        return creds[key]

    return re.sub(r"\{(\w+)\}", replace, template), missing


def content_hash(obj):
    return hashlib.sha256(json.dumps(sorted(obj.items())).encode()).hexdigest()


# ---------------------------------------------------------------------------
# Init mode — write catalog files and exit
# ---------------------------------------------------------------------------

def run_init():
    log.info("Init mode: writing catalog files to %s", CATALOG_DIR)
    creds = read_credentials()
    templates = read_templates()
    log.info("Loaded %d templates, %d credential keys", len(templates), len(creds))

    os.makedirs(CATALOG_DIR, exist_ok=True)
    written, skipped = [], []
    for catalog_name, template_content in templates.items():
        rendered, missing = render_template(template_content, creds)
        if missing:
            log.warning("Catalog %s missing credentials %s — skipping", catalog_name, missing)
            skipped.append(catalog_name)
            continue
        path = os.path.join(CATALOG_DIR, catalog_name + ".properties")
        with open(path, "w") as f:
            f.write(rendered)
        written.append(catalog_name)

    log.info("Wrote %d catalogs: %s", len(written), written)
    if skipped:
        log.warning("Skipped %d catalogs (missing creds): %s", len(skipped), skipped)


# ---------------------------------------------------------------------------
# Trino REST helpers (watch mode)
# ---------------------------------------------------------------------------

def _make_auth(user, password):
    return "Basic " + base64.b64encode("{}:{}".format(user, password).encode()).decode()


def trino_get(path, user, password):
    req = urllib.request.Request(
        TRINO_URL + path,
        headers={"X-Trino-User": user, "Authorization": _make_auth(user, password)},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode()), None
    except Exception as e:
        return None, str(e)


def wait_for_trino(user, password, timeout=300):
    deadline = time.time() + timeout
    while time.time() < deadline:
        data, _ = trino_get("/v1/info", user, password)
        if data and not data.get("starting", True):
            log.info("Trino is ready")
            return True
        log.info("Waiting for Trino to be ready...")
        time.sleep(5)
    return False


def get_running_query_count(user, password):
    data, err = trino_get("/v1/query?state=RUNNING", user, password)
    if err or data is None:
        log.warning("Could not fetch running queries: %s", err)
        return -1
    return len(data)


def wait_for_idle(user, password, timeout=3600):
    log.info("Waiting for cluster to go idle before restarting...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        count = get_running_query_count(user, password)
        if count == 0:
            log.info("No running queries — proceeding with restart")
            return
        if count < 0:
            log.warning("Could not determine query count — restarting anyway")
            return
        log.info("%d queries still running, waiting...", count)
        time.sleep(15)
    log.warning("Timed out waiting for queries to finish — restarting anyway")


# ---------------------------------------------------------------------------
# Kubernetes rolling restart
# ---------------------------------------------------------------------------

def read_namespace():
    try:
        with open(SA_NS) as f:
            return f.read().strip()
    except Exception:
        return os.environ.get("POD_NAMESPACE", "trino")


def k8s_patch(path, body):
    try:
        with open(SA_TOKEN) as f:
            token = f.read().strip()
    except Exception as e:
        log.error("Cannot read service account token: %s", e)
        return False

    ctx = ssl.create_default_context(cafile=SA_CA)
    req = urllib.request.Request(
        K8S_API + path,
        data=json.dumps(body).encode(),
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/merge-patch+json",
        },
        method="PATCH",
    )
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
            return resp.status in (200, 201, 204)
    except urllib.error.HTTPError as e:
        log.error("K8s PATCH %s → HTTP %s: %s", path, e.code, e.read().decode())
        return False
    except Exception as e:
        log.error("K8s PATCH %s failed: %s", path, e)
        return False


def trigger_restart(namespace):
    now = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    patch = {"spec": {"template": {"metadata": {"annotations": {
        "kubectl.kubernetes.io/restartedAt": now
    }}}}}
    for deployment in ["trino-coordinator", "trino-worker"]:
        path = "/apis/apps/v1/namespaces/{}/deployments/{}".format(namespace, deployment)
        if k8s_patch(path, patch):
            log.info("Triggered rolling restart of %s", deployment)
        else:
            log.error("Failed to restart %s", deployment)


# ---------------------------------------------------------------------------
# Watch mode
# ---------------------------------------------------------------------------

def wait_for_password(creds):
    password = creds.get("admin_password_plain", "")
    if password:
        return creds, password
    log.warning(
        "admin_password_plain not in credentials — query drain will be skipped until it appears. "
        "Add the plaintext admin password as 'admin_password_plain' to the terraform-trino secret."
    )
    while True:
        time.sleep(60)
        creds = read_credentials()
        password = creds.get("admin_password_plain", "")
        if password:
            log.info("admin_password_plain is now available")
            return creds, password


def main():
    log.info("Catalog refresher starting (watch mode)")
    creds = read_credentials()
    admin_user = creds.get("admin_user", "admin")
    creds, admin_password = wait_for_password(creds)

    if not wait_for_trino(admin_user, admin_password):
        log.error("Timed out waiting for Trino to be ready")
        return

    namespace = read_namespace()
    log.info("Watching credentials in namespace %s", namespace)

    last_cred_hash = content_hash(creds)
    last_tmpl_hash = content_hash(read_templates())

    while True:
        time.sleep(CHECK_INTERVAL)
        new_creds = read_credentials()
        new_templates = read_templates()
        new_cred_hash = content_hash(new_creds)
        new_tmpl_hash = content_hash(new_templates)

        if new_cred_hash == last_cred_hash and new_tmpl_hash == last_tmpl_hash:
            continue

        if new_cred_hash != last_cred_hash:
            log.info("Credentials changed")
        else:
            log.info("Templates changed")

        admin_user = new_creds.get("admin_user", admin_user)
        admin_password = new_creds.get("admin_password_plain", admin_password)

        wait_for_idle(admin_user, admin_password)
        trigger_restart(namespace)

        last_cred_hash = new_cred_hash
        last_tmpl_hash = new_tmpl_hash


if __name__ == "__main__":
    if "--init" in sys.argv:
        run_init()
    else:
        main()
