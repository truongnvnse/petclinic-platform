#!/usr/bin/env python3
"""Generate the Grafana dashboard JSON in k8s/base/observability/grafana-dashboards/.

PETPLAT-57. Seven dashboards: one overview, one per traced-and-scraped service,
one JVM. They are generated rather than hand-written because five of the seven
differ from each other by exactly one string — the `job` label — and hand-copying
a 400-line JSON five times is how a dashboard set drifts apart.

The generated files are committed. This script is how they are edited, not a
build step: `kubectl create configmap --from-file=` reads the JSON, and nothing
in the cluster runs Python.

    python3 scripts/generate-grafana-dashboards.py            # write
    python3 scripts/generate-grafana-dashboards.py --check    # verify, non-zero on drift

Every panel target is built by target(), which is the only place a target is
constructed. That is deliberate: it guarantees the two fields Grafana 10+
requires on every target — `refId` and an explicit `datasource` object — cannot
be forgotten on one panel out of eighty. A target missing either produces
"Failed to upgrade legacy queries" on the whole dashboard, not just that panel.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = REPO_ROOT / "k8s" / "base" / "observability" / "grafana-dashboards"

# The two datasource UIDs pinned in grafana.yaml. These strings are the contract
# between the provisioning ConfigMap and every panel below; a typo here shows up
# as "No Data" in every panel of every dashboard rather than as an error.
PROMETHEUS = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}

# The five services that expose a Prometheus registry and report traces — the
# same five prometheus.yaml scrapes and the same five that carry
# spring-boot-starter-zipkin. config-server, discovery-server and admin-server
# are absent because they have no micrometer-registry-prometheus dependency:
# a dashboard for one of them would render empty panels forever, and a scrape
# target for one would be a permanent `up == 0` firing ServiceDown.
#
# The port is carried for the dashboard description only — nothing queries it.
SERVICES = [
    ("api-gateway", 8080),
    ("customers-service", 8081),
    ("visits-service", 8082),
    ("vets-service", 8083),
    ("genai-service", 8084),
]

# The `namespace` template variable, shared by every dashboard. `label_values`
# over the five services' own `up` series, so the list is exactly the
# environments where they are actually running.
NAMESPACE_VAR = {
    "name": "namespace",
    "label": "Namespace",
    "type": "query",
    "datasource": PROMETHEUS,
    "query": {
        "query": 'label_values(up{job=~"api-gateway|customers-service|visits-service|vets-service|genai-service"}, namespace)',
        "refId": "StandardVariableQuery",
    },
    "refresh": 2,  # on time range change
    "includeAll": True,
    "multi": True,
    "current": {"selected": True, "text": "All", "value": "$__all"},
    "sort": 1,
}

SERVICE_VAR = {
    "name": "service",
    "label": "Service",
    "type": "query",
    "datasource": PROMETHEUS,
    "query": {
        "query": 'label_values(up{job=~"api-gateway|customers-service|visits-service|vets-service|genai-service"}, job)',
        "refId": "StandardVariableQuery",
    },
    "refresh": 2,
    "includeAll": True,
    "multi": True,
    "current": {"selected": True, "text": "All", "value": "$__all"},
    "sort": 1,
}

# ---------------------------------------------------------------------------
# Panel builders
# ---------------------------------------------------------------------------


def target(expr, legend="", ref_id="A", datasource=None, **extra):
    """Build one panel target.

    The single construction point for every query in this file — see the module
    docstring. `refId` and `datasource` are set here and cannot be omitted at a
    call site.
    """
    t = {
        "refId": ref_id,
        "datasource": datasource or PROMETHEUS,
        "expr": expr,
        "legendFormat": legend,
    }
    t.update(extra)
    return t


def _thresholds(steps=None):
    return {
        "mode": "absolute",
        "steps": steps or [{"color": "green", "value": None}],
    }


def timeseries(panel_id, title, targets, grid, unit="short", description="",
               decimals=None, stacking="none", thresholds=None, legend_calcs=None):
    defaults = {
        "unit": unit,
        "min": 0 if stacking == "none" and unit != "s" else None,
        "custom": {
            "drawStyle": "line",
            "lineInterpolation": "smooth",
            "lineWidth": 2,
            "fillOpacity": 10,
            "gradientMode": "none",
            "showPoints": "never",
            "spanNulls": False,
            "axisPlacement": "auto",
            "scaleDistribution": {"type": "linear"},
            "stacking": {"mode": stacking, "group": "A"},
            "hideFrom": {"legend": False, "tooltip": False, "viz": False},
        },
        "thresholds": _thresholds(thresholds),
    }
    if defaults["min"] is None:
        del defaults["min"]
    if decimals is not None:
        defaults["decimals"] = decimals

    return {
        "id": panel_id,
        "type": "timeseries",
        "title": title,
        "description": description,
        "datasource": PROMETHEUS,
        "gridPos": grid,
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {
            "legend": {
                "displayMode": "table",
                "placement": "bottom",
                "showLegend": True,
                "calcs": legend_calcs or ["mean", "max", "lastNotNull"],
            },
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
        "targets": targets,
    }


def stat(panel_id, title, targets, grid, unit="short", description="",
         decimals=None, thresholds=None, graph="area", text_mode="auto",
         color_mode="value"):
    defaults = {
        "unit": unit,
        "thresholds": _thresholds(thresholds),
        "color": {"mode": "thresholds"},
        "mappings": [],
    }
    if decimals is not None:
        defaults["decimals"] = decimals

    return {
        "id": panel_id,
        "type": "stat",
        "title": title,
        "description": description,
        "datasource": PROMETHEUS,
        "gridPos": grid,
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "colorMode": color_mode,
            "graphMode": graph,
            "justifyMode": "auto",
            "orientation": "auto",
            "textMode": text_mode,
        },
        "targets": targets,
    }


def table(panel_id, title, targets, grid, unit="short", description=""):
    return {
        "id": panel_id,
        "type": "table",
        "title": title,
        "description": description,
        "datasource": PROMETHEUS,
        "gridPos": grid,
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "custom": {"align": "auto", "cellOptions": {"type": "auto"}, "filterable": False},
                "thresholds": _thresholds(),
            },
            "overrides": [],
        },
        "options": {
            "showHeader": True,
            "cellHeight": "sm",
            "footer": {"show": False, "reducer": ["sum"], "countRows": False, "fields": ""},
        },
        # No `reduce` transformation: the target is an instant query in table
        # format, so Prometheus already returns exactly one row and the only
        # cleanup needed is dropping the timestamp column and renaming the
        # value. Adding `reduce` on top would rename every column to
        # "<name> (lastNotNull)" and the organize rule below would stop
        # matching anything.
        "transformations": [
            {"id": "organize", "options": {
                "excludeByName": {"Time": True},
                "renameByName": {"Value": "req/s", "uri": "Endpoint"},
                "indexByName": {},
            }},
        ],
        "targets": targets,
    }


def logs(panel_id, title, expr, grid, description=""):
    """A Loki panel.

    Its target carries `datasource: {type: loki, uid: loki}` rather than the
    Prometheus uid — same two required fields, different datasource. This is the
    only query in the dashboard set that is not PromQL, and it is here so the
    Loki datasource grafana.yaml provisions is actually exercised: a datasource
    nothing queries is a datasource whose misconfiguration nothing reveals.
    """
    return {
        "id": panel_id,
        "type": "logs",
        "title": title,
        "description": description,
        "datasource": LOKI,
        "gridPos": grid,
        "options": {
            "showTime": True,
            "showLabels": False,
            "showCommonLabels": False,
            "wrapLogMessage": True,
            "prettifyLogMessage": False,
            "enableLogDetails": True,
            "dedupStrategy": "none",
            "sortOrder": "Descending",
        },
        "targets": [
            target(expr, datasource=LOKI, queryType="range", editorMode="code")
        ],
    }


def row(panel_id, title, grid, collapsed=False):
    return {
        "id": panel_id,
        "type": "row",
        "title": title,
        "collapsed": collapsed,
        "gridPos": grid,
        "panels": [],
    }


def grid(y, x=0, w=24, h=8):
    return {"h": h, "w": w, "x": x, "y": y}


def dashboard(uid, title, description, tags, panels, templating=None, refresh="30s"):
    return {
        "uid": uid,
        "title": title,
        "description": description,
        "tags": ["petclinic"] + tags,
        "timezone": "browser",
        # Grafana migrates this forward on import; 39 is the version whose
        # timeseries/fieldConfig shape the panels above are written in.
        "schemaVersion": 39,
        "version": 1,
        "refresh": refresh,
        "editable": True,
        "graphTooltip": 1,
        "time": {"from": "now-6h", "to": "now"},
        "timepicker": {},
        "templating": {"list": templating or []},
        "annotations": {"list": []},
        "panels": panels,
    }


# ---------------------------------------------------------------------------
# Overview
# ---------------------------------------------------------------------------


def overview_dashboard():
    ns = 'namespace=~"$namespace"'
    svc = 'job=~"$service"'
    sel = f"{ns}, {svc}"

    reqs = f"sum by (job) (rate(http_server_requests_seconds_count{{{sel}}}[5m]))"
    errs = (
        f"100 * sum by (job) (rate(http_server_requests_seconds_count{{{sel}, status=~\"5..\"}}[5m]))"
        f" / clamp_min(sum by (job) (rate(http_server_requests_seconds_count{{{sel}}}[5m])), 0.0001)"
    )

    def quantile(q):
        return (
            f"histogram_quantile({q}, sum by (job, le) "
            f"(rate(http_server_requests_seconds_bucket{{{sel}}}[5m])))"
        )

    heap = f"sum by (job) (jvm_memory_used_bytes{{{sel}, area=\"heap\"}})"
    gc_pause = (
        f"sum by (job) (rate(jvm_gc_pause_seconds_sum{{{sel}}}[5m]))"
        f" / clamp_min(sum by (job) (rate(jvm_gc_pause_seconds_count{{{sel}}}[5m])), 0.0001)"
    )

    y = 0
    panels = [
        stat(1, "Requests per second",
             [target(reqs, "{{job}}")], grid(y, 0, 6, 5), unit="reqps", decimals=2,
             description="Total request rate across the selected services."),
        stat(2, "Error rate (5xx)",
             [target(errs, "{{job}}")], grid(y, 6, 6, 5), unit="percent", decimals=2,
             description="5xx responses as a share of all responses. The HighErrorRate rule fires above 5%.",
             thresholds=[
                 {"color": "green", "value": None},
                 {"color": "orange", "value": 1},
                 {"color": "red", "value": 5},
             ]),
        stat(3, "p95 latency",
             [target(quantile(0.95), "{{job}}")], grid(y, 12, 6, 5), unit="s", decimals=3,
             description="The HighLatency rule fires above 0.5s sustained for 5 minutes.",
             thresholds=[
                 {"color": "green", "value": None},
                 {"color": "orange", "value": 0.25},
                 {"color": "red", "value": 0.5},
             ]),
        stat(4, "Services up",
             [target(f"up{{{sel}}}", "{{job}}")], grid(y, 18, 6, 5),
             description="1 when Prometheus can scrape the target. 0 means the pod is gone or the actuator is not answering.",
             thresholds=[
                 {"color": "red", "value": None},
                 {"color": "green", "value": 1},
             ],
             color_mode="background", graph="none", text_mode="value_and_name"),

        row(5, "Traffic", grid(y + 5, 0, 24, 1)),

        timeseries(6, "Request rate by service", [target(reqs, "{{job}}")],
                   grid(y + 6, 0, 12, 8), unit="reqps",
                   description="One line per service, from http_server_requests_seconds_count."),
        timeseries(7, "Error rate by service", [target(errs, "{{job}}")],
                   grid(y + 6, 12, 12, 8), unit="percent", decimals=2,
                   description="5xx as a percentage of all responses, per service.",
                   thresholds=[
                       {"color": "green", "value": None},
                       {"color": "orange", "value": 1},
                       {"color": "red", "value": 5},
                   ]),
        timeseries(8, "p95 latency by service", [target(quantile(0.95), "{{job}}")],
                   grid(y + 14, 0, 12, 8), unit="s", decimals=3,
                   description="95th percentile response time, pooled across every endpoint of each service."),
        timeseries(9, "JVM heap used by service", [target(heap, "{{job}}")],
                   grid(y + 14, 12, 12, 8), unit="bytes",
                   description="Heap in use. Compare against the 512Mi container limit — the HighMemoryUsage rule fires at 80% of the limit."),

        row(10, "Logs", grid(y + 22, 0, 24, 1)),

        logs(11, "ERROR lines (all namespaces)", '{namespace=~"petclinic-.*"} |= "ERROR"',
             grid(y + 23, 0, 24, 9),
             description="Live from Loki. This is the same selector the LogErrorSpike rule evaluates, so a spike here and a firing alert are the same event."),
    ]

    return dashboard(
        "petclinic-overview",
        "Petclinic — Overview",
        "All five scraped services at a glance: traffic, errors, latency, heap, and the ERROR log stream.",
        ["overview"],
        panels,
        templating=[NAMESPACE_VAR, SERVICE_VAR],
    )


# ---------------------------------------------------------------------------
# Per-service
# ---------------------------------------------------------------------------


def service_dashboard(name, port):
    ns = 'namespace=~"$namespace"'
    sel = f'job="{name}", {ns}'

    reqs = f"sum(rate(http_server_requests_seconds_count{{{sel}}}[5m]))"
    errs = (
        f"100 * sum(rate(http_server_requests_seconds_count{{{sel}, status=~\"5..\"}}[5m]))"
        f" / clamp_min(sum(rate(http_server_requests_seconds_count{{{sel}}}[5m])), 0.0001)"
    )

    def quantile(q, by=""):
        agg = f"sum by (le{by}) " if by else "sum by (le) "
        return f"histogram_quantile({q}, {agg}(rate(http_server_requests_seconds_bucket{{{sel}}}[5m])))"

    heap_used = f'sum(jvm_memory_used_bytes{{{sel}, area="heap"}})'
    heap_max = f'sum(jvm_memory_max_bytes{{{sel}, area="heap"}})'

    y = 0
    panels = [
        stat(1, "Requests per second", [target(reqs)], grid(y, 0, 5, 5),
             unit="reqps", decimals=2),
        stat(2, "Error rate (5xx)", [target(errs)], grid(y, 5, 5, 5),
             unit="percent", decimals=2,
             thresholds=[
                 {"color": "green", "value": None},
                 {"color": "orange", "value": 1},
                 {"color": "red", "value": 5},
             ]),
        stat(3, "p95 latency", [target(quantile(0.95))], grid(y, 10, 4, 5),
             unit="s", decimals=3,
             thresholds=[
                 {"color": "green", "value": None},
                 {"color": "orange", "value": 0.25},
                 {"color": "red", "value": 0.5},
             ]),
        stat(4, "p99 latency", [target(quantile(0.99))], grid(y, 14, 4, 5),
             unit="s", decimals=3),
        stat(5, "Heap used", [target(heap_used)], grid(y, 18, 6, 5),
             unit="bytes",
             description="Container limit is 512Mi. HighMemoryUsage fires at 80% of it."),

        row(6, "Traffic", grid(y + 5, 0, 24, 1)),

        timeseries(7, "Request rate by endpoint",
                   [target(f"sum by (uri) (rate(http_server_requests_seconds_count{{{sel}}}[5m]))",
                           "{{uri}}")],
                   grid(y + 6, 0, 12, 9), unit="reqps",
                   description="Which endpoints are carrying the traffic. Spring Boot's `uri` tag is the templated path, so /owners/{ownerId} is one series rather than one per owner."),
        timeseries(8, "Responses by status",
                   [target(f"sum by (status) (rate(http_server_requests_seconds_count{{{sel}}}[5m]))",
                           "{{status}}")],
                   grid(y + 6, 12, 12, 9), unit="reqps", stacking="normal",
                   description="Stacked by HTTP status. The 5xx band is what the HighErrorRate rule watches."),
        timeseries(9, "Latency percentiles",
                   [target(quantile(0.50), "p50", ref_id="A"),
                    target(quantile(0.95), "p95", ref_id="B"),
                    target(quantile(0.99), "p99", ref_id="C")],
                   grid(y + 15, 0, 12, 9), unit="s", decimals=3,
                   description="p50, p95 and p99 pooled across every endpoint. Three targets in one panel, so the refIds run A, B, C."),
        table(10, "Busiest endpoints",
              [target(f"topk(10, sum by (uri) (rate(http_server_requests_seconds_count{{{sel}}}[5m])))",
                      "", instant=True, format="table")],
              grid(y + 15, 12, 12, 9), unit="reqps",
              description="Top 10 endpoints by request rate, as an instant query at the end of the time range."),

        row(11, "JVM", grid(y + 24, 0, 24, 1)),

        timeseries(12, "Heap used vs limit",
                   [target(heap_used, "used", ref_id="A"),
                    target(heap_max, "max", ref_id="B")],
                   grid(y + 25, 0, 12, 8), unit="bytes",
                   description="Used against the JVM's own max. The container limit in the Deployment is the other ceiling, and the lower of the two is what OOMs first."),
        timeseries(13, "GC pause — average duration by cause",
                   [target(f"sum by (cause) (rate(jvm_gc_pause_seconds_sum{{{sel}}}[5m]))"
                           f" / clamp_min(sum by (cause) (rate(jvm_gc_pause_seconds_count{{{sel}}}[5m])), 0.0001)",
                           "{{cause}}")],
                   grid(y + 25, 12, 12, 8), unit="s", decimals=4,
                   description="Mean pause length per GC cause. A rising mean with a flat count means the collector is doing more work per cycle."),

        row(14, "Logs", grid(y + 33, 0, 24, 1)),

        logs(15, f"{name} — recent logs",
             f'{{namespace=~"petclinic-.*", pod=~"{name}-.*"}}',
             grid(y + 34, 0, 24, 9),
             description=f"Everything this service has logged. Pod names carry the ReplicaSet hash, so the selector is a prefix match on `{name}-`."),
    ]

    return dashboard(
        f"petclinic-service-{name}",
        f"Petclinic — {name}",
        f"{name} (port {port}): traffic, errors, latency percentiles, endpoints, JVM and logs.",
        ["service", name],
        panels,
        templating=[NAMESPACE_VAR],
    )


# ---------------------------------------------------------------------------
# JVM
# ---------------------------------------------------------------------------


def jvm_dashboard():
    ns = 'namespace=~"$namespace"'
    svc = 'job=~"$service"'
    sel = f"{ns}, {svc}"

    def heap_by(area, by="job"):
        return f'sum by ({by}) (jvm_memory_used_bytes{{{sel}, area="{area}"}})'

    y = 0
    panels = [
        stat(1, "Heap used", [target(heap_by("heap"), "{{job}}")],
             grid(y, 0, 6, 5), unit="bytes"),
        stat(2, "Non-heap used", [target(heap_by("nonheap"), "{{job}}")],
             grid(y, 6, 6, 5), unit="bytes",
             description="Metaspace, code cache and compressed class space. Grows with the number of loaded classes and plateaus; a non-heap that keeps climbing is a classloader leak."),
        stat(3, "Live threads", [target(f"sum by (job) (jvm_threads_live_threads{{{sel}}})", "{{job}}")],
             grid(y, 12, 6, 5), unit="short"),
        stat(4, "GC pause rate",
             [target(f"sum by (job) (rate(jvm_gc_pause_seconds_count{{{sel}}}[5m]))", "{{job}}")],
             grid(y, 18, 6, 5), unit="cps", decimals=3,
             description="Garbage collections per second, all causes pooled."),

        row(5, "Memory", grid(y + 5, 0, 24, 1)),

        timeseries(6, "Heap used by service",
                   [target(heap_by("heap"), "{{job}}")],
                   grid(y + 6, 0, 12, 8), unit="bytes",
                   description="jvm_memory_used_bytes over area=heap, summed across the pool tags."),
        timeseries(7, "Heap used vs max",
                   [target(f'sum by (job) (jvm_memory_used_bytes{{{sel}, area="heap"}})', "used — {{job}}", ref_id="A"),
                    target(f'sum by (job) (jvm_memory_max_bytes{{{sel}, area="heap"}})', "max — {{job}}", ref_id="B")],
                   grid(y + 6, 12, 12, 8), unit="bytes",
                   description="Two targets in one panel — refId A for used, B for max. `max` is -1 when the JVM reports no ceiling, which is why this can read as a flat line at the bottom."),
        timeseries(8, "Heap by memory pool",
                   [target(f'sum by (job, id) (jvm_memory_used_bytes{{{sel}, area="heap"}})', "{{job}} · {{id}}")],
                   grid(y + 14, 0, 12, 8), unit="bytes",
                   description="Eden, survivor and old generation separately. An old generation that only ratchets upward between full GCs is the shape of a leak; a sawtooth is normal."),
        timeseries(9, "Non-heap by memory pool",
                   [target(f'sum by (job, id) (jvm_memory_used_bytes{{{sel}, area="nonheap"}})', "{{job}} · {{id}}")],
                   grid(y + 14, 12, 12, 8), unit="bytes"),

        row(10, "Garbage collection", grid(y + 22, 0, 24, 1)),

        timeseries(11, "GC rate by cause",
                   [target(f"sum by (job, cause) (rate(jvm_gc_pause_seconds_count{{{sel}}}[5m]))",
                           "{{job}} · {{cause}}")],
                   grid(y + 23, 0, 12, 8), unit="cps", decimals=3,
                   description="Collections per second. Allocation Failure is the ordinary young-generation case; a rising G1 Evacuation Pause or Full GC is the one to look at."),
        timeseries(12, "GC pause — average duration by cause",
                   [target(f"sum by (job, cause) (rate(jvm_gc_pause_seconds_sum{{{sel}}}[5m]))"
                           f" / clamp_min(sum by (job, cause) (rate(jvm_gc_pause_seconds_count{{{sel}}}[5m])), 0.0001)",
                           "{{job}} · {{cause}}")],
                   grid(y + 23, 12, 12, 8), unit="s", decimals=4),
        timeseries(13, "GC pause — total time per second",
                   [target(f"sum by (job) (rate(jvm_gc_pause_seconds_sum{{{sel}}}[5m]))", "{{job}}")],
                   grid(y + 31, 0, 12, 8), unit="s",
                   description="Seconds spent paused per second of wall clock, summed over all collectors. Approaching 1 means the JVM is spending all its time collecting."),
        timeseries(14, "GC overhead",
                   [target(f"max by (job) (jvm_gc_overhead{{{sel}}})", "{{job}}")],
                   grid(y + 31, 12, 12, 8), unit="percentunit", decimals=3,
                   description="Micrometer's own estimate of the fraction of time spent in GC, as a 0–1 ratio."),

        row(15, "Threads and process", grid(y + 39, 0, 24, 1)),

        timeseries(16, "Thread count",
                   [target(f"sum by (job) (jvm_threads_live_threads{{{sel}}})", "live — {{job}}", ref_id="A"),
                    target(f"sum by (job) (jvm_threads_daemon_threads{{{sel}}})", "daemon — {{job}}", ref_id="B"),
                    target(f"sum by (job) (jvm_threads_peak_threads{{{sel}}})", "peak — {{job}}", ref_id="C")],
                   grid(y + 40, 0, 12, 8), unit="short",
                   description="Three targets, so refIds A, B and C. A live count that climbs and never comes back down is the classic thread leak."),
        timeseries(17, "Threads by state",
                   [target(f"sum by (job, state) (jvm_threads_states_threads{{{sel}}})", "{{job}} · {{state}}")],
                   grid(y + 40, 12, 12, 8), unit="short",
                   description="A growing `blocked` or `waiting` band is where a thread leak or a lock contention problem shows up first."),
        timeseries(18, "Process CPU",
                   [target(f"sum by (job) (process_cpu_usage{{{sel}}})", "{{job}}")],
                   grid(y + 48, 0, 12, 8), unit="percentunit", decimals=3,
                   description="Process CPU as a 0–1 ratio of one core. The HPA in prod scales on this."),
        timeseries(19, "Classes loaded",
                   [target(f"sum by (job) (jvm_classes_loaded_classes{{{sel}}})", "loaded — {{job}}", ref_id="A"),
                    target(f"sum by (job) (jvm_classes_unloaded_classes_total{{{sel}}})", "unloaded (total) — {{job}}", ref_id="B")],
                   grid(y + 48, 12, 12, 8), unit="short",
                   description="Loaded classes should plateau after startup. Steady growth alongside rising non-heap is a classloader leak — usually a proxy or a dynamic class generator, not application code."),
    ]

    return dashboard(
        "petclinic-jvm",
        "Petclinic — JVM",
        "Heap, garbage collection, threads and classes across all five services.",
        ["jvm"],
        panels,
        templating=[NAMESPACE_VAR, SERVICE_VAR],
    )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def build_all():
    dashboards = [overview_dashboard()]
    for name, port in SERVICES:
        dashboards.append(service_dashboard(name, port))
    dashboards.append(jvm_dashboard())
    return dashboards


def render(d):
    return json.dumps(d, indent=2, ensure_ascii=False) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="Do not write; exit non-zero if any file on disk differs from the generated output.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=OUTPUT_DIR,
        help=f"Where to write the JSON (default: {OUTPUT_DIR.relative_to(REPO_ROOT)}).",
    )
    args = parser.parse_args()

    out = args.output_dir
    if not args.check:
        out.mkdir(parents=True, exist_ok=True)

    drift = []
    for d in build_all():
        path = out / f"{d['uid']}.json"
        content = render(d)

        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                drift.append(path.name)
            continue

        path.write_text(content, encoding="utf-8")
        panels = sum(1 for p in d["panels"] if p["type"] != "row")
        print(f"wrote {path.relative_to(REPO_ROOT)}  ({panels} panels)")

    if args.check and drift:
        print("out of date:", ", ".join(drift), file=sys.stderr)
        print("run: python3 scripts/generate-grafana-dashboards.py", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
