import json
import os
import random
import time

from flask import Flask, jsonify

app = Flask(__name__)
VERSION = os.getenv("APP_VERSION", "v1")
FAIL_RATE = float(os.getenv("FAIL_RATE", "0"))


def log_event(level, msg, **fields):
    print(json.dumps({"level": level, "msg": msg, "version": VERSION, **fields}), flush=True)


@app.route("/")
def index():
    if random.random() < FAIL_RATE:
        log_event("ERROR", "random failure injected", path="/")
        return jsonify(error="injected failure"), 500
    log_event("INFO", "request served", path="/")
    return jsonify(service="sentinelops-app", version=VERSION)


@app.route("/health")
def health():
    return jsonify(status="ok"), 200


@app.route("/error")
def error():
    log_event("ERROR", "forced error", path="/error")
    return jsonify(error="forced error"), 500


@app.route("/slow")
def slow():
    time.sleep(3)
    log_event("WARN", "slow response", path="/slow", delay_seconds=3)
    return jsonify(status="slow ok")


@app.route("/cpu")
def cpu():
    end = time.time() + 10
    while time.time() < end:
        sum(i * i for i in range(10000))
    log_event("WARN", "cpu burn finished", path="/cpu")
    return jsonify(status="cpu burn done")
